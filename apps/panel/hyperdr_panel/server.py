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
import time
from http.server import ThreadingHTTPServer
from pathlib import Path
from urllib.parse import quote

from . import api, phone_log, security
from .config import PREFERRED_PORT
from .handler import Handler
from .job import active_session_id, shutdown
from .phone_connection import PhoneConnections
from .session import cleanup_expired_sessions

# Bounded so one client that connects and never finishes its TLS handshake
# cannot hold a worker and a connection slot forever. The timeout covers only
# the handshake; handlers restore their own read timeout afterwards.
TLS_HANDSHAKE_TIMEOUT_SECONDS = max(
    0.5, float(os.environ.get("HYPERDR_TLS_HANDSHAKE_TIMEOUT_SECONDS", "5")))

class PanelServer(PhoneConnections, ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.connection_slots = threading.BoundedSemaphore(
            max(1, int(os.environ.get("HYPERDR_MAX_CONNECTIONS", "32"))))

    def process_request(self, request, client_address):
        if not self.connection_slots.acquire(blocking=False):
            try:
                if isinstance(request, ssl.SSLSocket):
                    # Writing to a TLS socket that has not handshaked would start
                    # the handshake here in the accept thread. A saturated server
                    # just drops such a connection.
                    phone_log.log("connection-saturated", transport="tls",
                                  peer=client_address[0])
                else:
                    request.sendall(
                        b"HTTP/1.1 503 Service Unavailable\r\n"
                        b"Connection: close\r\nContent-Length: 0\r\n\r\n")
            except OSError:
                pass
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
            if isinstance(request, ssl.SSLSocket) and not self._handshake(request, client_address):
                self.shutdown_request(request)
                return
            super().process_request_thread(request, client_address)
        finally:
            self.connection_slots.release()

    def _handshake(self, request, client_address) -> bool:
        """Complete the TLS handshake here, never at accept time.

        `accept()` must return immediately: a client that connects and stalls
        before or during the handshake would otherwise queue every later
        request — including the whole phone workbench — behind itself, and
        would stall `shutdown()` just as reliably.
        """
        started = time.monotonic()
        request.settimeout(TLS_HANDSHAKE_TIMEOUT_SECONDS)
        try:
            request.do_handshake()
        except (OSError, ValueError) as error:
            phone_log.log("tls-handshake", result="failed",
                          error="timeout" if isinstance(error, TimeoutError) else type(error).__name__,
                          elapsed=time.monotonic() - started, peer=client_address[0])
            return False
        finally:
            request.settimeout(None)
        elapsed = time.monotonic() - started
        if elapsed >= 1.0:
            phone_log.log("tls-handshake", result="ok", elapsed=elapsed,
                          peer=client_address[0])
        return True

    access_token: str
    cookie_secure: bool
    public_scheme: str
    context: api.Context
    login_throttle: security.LoginThrottle



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


def build_server(host: str, port: int, token: str, scheme: str,
                 *, desktop: bool = False, phone_only: bool = False) -> PanelServer:
    server = PanelServer((host, port), Handler)
    server.access_token = token
    server.public_scheme = scheme
    server.cookie_secure = scheme == "https" or os.environ.get("HYPERDR_COOKIE_SECURE") == "1"
    server.login_throttle = security.LoginThrottle()
    server.phone_only = phone_only
    server.init_phone()
    server.retired = False
    loopback = host.lower() in {"127.0.0.1", "localhost", "::1"}
    server.context = api.Context(
        # TLS only. Chromium/WebView also treats a loopback HTTP origin as a
        # trustworthy secure context, but the page observes that for itself
        # through window.isSecureContext, so the server does not report it.
        transport_secure=scheme == "https",
        # Absolute source paths are a local desktop capability; never expose
        # that route if a desktop process was deliberately rebound to LAN.
        native_path_input=desktop and loopback,
        # Saving directly to the user's file system is likewise desktop-only;
        # the separately bound phone server is built with desktop=False.
        native_path_output=desktop and loopback,
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
    # The editor stays local. Its separate phone listener opens on demand.
    host = os.environ.get("HYPERDR_HOST", "127.0.0.1")
    port = find_free_port(host, int(os.environ.get("HYPERDR_PORT", PREFERRED_PORT)))
    token = security.check_token_format(
        os.environ.get("HYPERDR_ACCESS_TOKEN") or security.make_token())
    certificate = os.environ.get("HYPERDR_TLS_CERT", "")
    key = os.environ.get("HYPERDR_TLS_KEY", "")

    # Loopback already provides a secure browser context. Phone certificates
    # must not make the local editor require installation of a desktop root CA.
    loopback = host.lower() in {"127.0.0.1", "localhost", "::1"}
    tls_context = load_tls_context(certificate, key) if certificate and key and not loopback else None
    scheme = "https" if tls_context else "http"

    server = build_server(host, port, token, scheme, desktop=desktop)
    if tls_context is not None:
        # Deferred handshake: `accept()` only accepts, `PanelServer._handshake`
        # runs the TLS handshake per connection inside its worker.
        server.socket = tls_context.wrap_socket(
            server.socket, server_side=True, do_handshake_on_connect=False)

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
    print("手机导入与预览：在编辑器中点击“连接手机”，扫描二维码。")
    if removed:
        print(f"已清理 {removed} 个过期任务。")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n已停止。")
    finally:
        cleanup_stop.set()
        cleanup_thread.join(timeout=5)
        server.stop_phone()
        shutdown()
        server.server_close()
