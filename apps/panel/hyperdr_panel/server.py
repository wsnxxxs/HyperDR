"""Starting the panel: ports, TLS, addresses, and the background cleanup.

The service is meant to be started by double-clicking `Start.bat` and stopped by
closing the window, so everything here optimises for that: it picks a free port
rather than failing, prints the phone-reachable URL, and cleans up its own
workspace on a timer.
"""
from __future__ import annotations

import os
import socket
import ssl
import threading
import webbrowser
from http.server import ThreadingHTTPServer
from pathlib import Path
from urllib.parse import quote

from . import api, security
from .config import IS_WINDOWS, PREFERRED_PORT
from .handler import Handler
from .job import active_session_id, shutdown
from .picker import pick_via_subprocess
from .session import cleanup_expired_sessions

# tkinter must own the thread it runs on, so the native dialog is a subprocess
# and only one may be open at a time.
_FOLDER_DIALOG_LOCK = threading.Lock()


class PanelServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.connection_slots = threading.BoundedSemaphore(
            max(1, int(os.environ.get("HYPERDR_MAX_CONNECTIONS", "32"))))

    def process_request(self, request, client_address):
        if not self.connection_slots.acquire(blocking=False):
            try:
                request.sendall(
                    b"HTTP/1.1 503 Service Unavailable\r\n"
                    b"Connection: close\r\nContent-Length: 0\r\n\r\n")
            finally:
                request.close()
            return
        try:
            super().process_request(request, client_address)
        except Exception:
            self.connection_slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.connection_slots.release()

    access_token: str
    cookie_secure: bool
    public_scheme: str
    context: api.Context
    login_throttle: security.LoginThrottle


def choose_output_directory() -> str:
    """Open the native folder picker on the HyperDR host computer."""
    if not IS_WINDOWS:
        raise OSError("当前系统暂不支持原生导出文件夹选择。")
    with _FOLDER_DIALOG_LOCK:
        selected, error = pick_via_subprocess("folder")
    if error:
        raise RuntimeError(error)
    return selected


def find_free_port(host: str, preferred: int = PREFERRED_PORT) -> int:
    for port in [preferred] + list(range(preferred + 1, preferred + 44)):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
            try:
                probe.bind((host, port))
                return port
            except OSError:
                continue
    raise OSError("找不到可用端口。")


def lan_addresses() -> list[str]:
    """Addresses a phone on the same network could use, best guess first."""
    found: set[str] = set()
    preferred = ""
    try:
        found.update(socket.gethostbyname_ex(socket.gethostname())[2])
    except OSError:
        pass
    try:
        # Connecting a UDP socket sends nothing but reveals which local address
        # the routing table would use, which is the one a phone can reach.
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
            probe.connect(("192.0.2.1", 80))
            preferred = probe.getsockname()[0]
            found.add(preferred)
    except OSError:
        pass
    addresses = sorted(ip for ip in found if ip and not ip.startswith(("127.", "169.254.")))
    if preferred in addresses:
        addresses.remove(preferred)
        addresses.insert(0, preferred)
    return addresses


def _cleanup_forever(stop: threading.Event, interval_seconds: float) -> None:
    """Bound workspace growth without removing files an active job is using."""
    while not stop.wait(interval_seconds):
        active = active_session_id()
        removed = cleanup_expired_sessions(
            protected_session_ids={active} if active else set())
        if removed:
            print(f"已定时清理 {removed} 个过期任务。")


def build_server(host: str, port: int, token: str, scheme: str) -> PanelServer:
    server = PanelServer((host, port), Handler)
    server.access_token = token
    server.public_scheme = scheme
    server.cookie_secure = scheme == "https" or os.environ.get("HYPERDR_COOKIE_SECURE") == "1"
    server.login_throttle = security.LoginThrottle()
    server.context = api.Context(
        output_selections={},
        secure_context_expected=scheme == "https",
        choose_output_directory=choose_output_directory if IS_WINDOWS else None,
    )
    return server


def load_tls_context(certificate: str, key: str) -> ssl.SSLContext | None:
    """Build the TLS context, or explain in plain language why it cannot be.

    A broken certificate must never surface as a traceback: the panel is
    started by double-clicking, so the window is the only place the person will
    ever look for an explanation.
    """
    missing = [path for path in (certificate, key) if not Path(path).is_file()]
    if missing:
        print("警告：TLS 证书文件不存在，本次以 HTTP 启动。")
        for path in missing:
            print(f"  找不到：{path}")
        return None
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    try:
        context.load_cert_chain(certificate, key)
    except (ssl.SSLError, OSError, ValueError) as error:
        print("警告：TLS 证书无法加载，本次以 HTTP 启动。")
        print(f"  证书：{certificate}")
        print(f"  私钥：{key}")
        print(f"  原因：{error}")
        print("  常见原因是证书与私钥不是同一对，或私钥被口令保护。")
        print("  重新签发一对证书即可，iPhone 上已安装的根证书无需重装。")
        return None
    return context


def serve(*, desktop: bool = False) -> None:
    # A desktop WebView only needs loopback. LAN mode keeps the historical
    # 0.0.0.0 default and is still started explicitly by Start.bat.
    host = os.environ.get("HYPERDR_HOST", "127.0.0.1" if desktop else "0.0.0.0")
    port = find_free_port(host, int(os.environ.get("HYPERDR_PORT", PREFERRED_PORT)))
    token = security.check_token_format(
        os.environ.get("HYPERDR_ACCESS_TOKEN") or security.make_token())
    certificate = os.environ.get("HYPERDR_TLS_CERT", "")
    key = os.environ.get("HYPERDR_TLS_KEY", "")

    # The scheme has to be decided before the server is built, because the
    # cookie and secure-context policies are derived from it.
    tls_context = load_tls_context(certificate, key) if certificate and key else None
    scheme = "https" if tls_context else "http"

    server = build_server(host, port, token, scheme)
    if tls_context is not None:
        server.socket = tls_context.wrap_socket(server.socket, server_side=True)

    removed = cleanup_expired_sessions()
    cleanup_minutes = max(1, min(1440, int(os.environ.get("HYPERDR_CLEANUP_MINUTES", "15"))))
    cleanup_stop = threading.Event()
    cleanup_thread = threading.Thread(
        target=_cleanup_forever, args=(cleanup_stop, cleanup_minutes * 60.0),
        name="hyperdr-workspace-cleanup", daemon=True)
    cleanup_thread.start()

    local_url = f"{scheme}://127.0.0.1:{port}/?token={quote(token)}"
    if desktop:
        # Tauri reads this ASCII prefix from the sidecar's stdout and opens
        # the existing HTTP panel at the announced tokenised URL.
        print(f"HYPERDR_READY {local_url}", flush=True)
    print("HyperDR 已启动。关闭此窗口即可停止服务。")
    print(f"本机地址：{local_url}")
    if not desktop:
        for ip in lan_addresses():
            print(f"iPhone 地址：{scheme}://{ip}:{port}/?token={quote(token)}")
    if not desktop and scheme == "http":
        print("提示：局域网 HTTP 可以上传和转换，但 Safari WebGPU HDR 需要受信任的 HTTPS。")
    if removed:
        print(f"已清理 {removed} 个过期任务。")
    if not desktop and os.environ.get("HYPERDR_NO_BROWSER") != "1":
        try:
            webbrowser.open(local_url)
        except Exception:
            pass
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n已停止。")
    finally:
        cleanup_stop.set()
        cleanup_thread.join(timeout=5)
        shutdown()
        server.server_close()
