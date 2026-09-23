"""Desktop-owned phone listener and certificate onboarding lifecycle."""
from __future__ import annotations

import threading
import time
from urllib.parse import quote

from . import phone_log, phone_setup, phone_tls, security


class PhoneConnections:
    def init_phone(self):
        self.phone_server = None
        self.setup_server = None
        self.phone_lock = threading.RLock()
        self.tls_job = "idle"
        self.tls_error = ""
        self.tls_generation = 0
        self._certificate = None
        self._checked_at = 0
        self._addresses = []
        self.phone_ordinary = False

    def certificate_status(self, *, refresh=False):
        from .server import lan_addresses
        if refresh or self._certificate is None or time.monotonic() - self._checked_at > 10:
            self._addresses = lan_addresses()
            self._certificate = phone_tls.status(self._addresses)
            self._checked_at = time.monotonic()
        return self._certificate

    def phone_status(self):
        with self.phone_lock:
            certificate = self.certificate_status()
            phone = self.phone_server
            if (phone and not self.phone_ordinary and self.tls_job == "idle"
                    and certificate["state"] == "renew" and certificate["canPrepare"]):
                self.prepare_phone_tls(self.context.workbench.owner, setup=False)
            setup = self.setup_server
            urls = [] if not phone else [
                f"{phone.public_scheme}://{ip}:{phone.server_port}/phone?token={quote(phone.access_token)}"
                for ip in self._addresses]
            setup_urls = [] if not setup or setup.expires <= time.monotonic() else [
                f"http://{ip}:{setup.server_port}/setup?token={quote(setup.access_token)}"
                for ip in self._addresses if ip in setup.addresses]
            return {"urls": urls, "setupUrls": setup_urls,
                    "secure": bool(phone and phone.public_scheme == "https"),
                    "tls": {**certificate, "job": self.tls_job, "jobError": self.tls_error},
                    **self.context.workbench.snapshot()}

    def _start_phone(self, secure):
        from .server import build_server, find_free_port, load_tls_context
        tls = load_tls_context(*map(str, phone_tls.paths())) if secure else None
        if secure and not tls:
            raise ValueError("证书无法载入，请重试准备证书。")
        scheme = "https" if tls else "http"
        port = find_free_port("0.0.0.0", 8757)
        phone = build_server("0.0.0.0", port, security.make_token(), scheme, phone_only=True)
        phone.context.workbench = self.context.workbench
        phone.phone_controller = self
        if tls:
            # Deferred handshake: `accept()` only accepts, `PanelServer._handshake`
            # runs the TLS handshake per connection inside its worker.
            phone.socket = tls.wrap_socket(
                phone.socket, server_side=True, do_handshake_on_connect=False)
        self.phone_server = phone
        threading.Thread(target=phone.serve_forever, daemon=True, name="hyperdr-phone").start()
        phone_log.log("phone-listener-start", scheme=scheme, port=phone.server_port)

    def _close_setup(self):
        if self.setup_server:
            phone_log.log("setup-listener-stop", port=self.setup_server.server_port)
            phone_setup.close(self.setup_server)
            self.setup_server = None

    def _close_phone_listener(self):
        self._close_setup()
        if self.phone_server:
            phone_log.log("phone-listener-stop", port=self.phone_server.server_port)
            self.phone_server.retired = True
            with self.context.workbench.changed:
                self.context.workbench.notify()
            self.phone_server.shutdown()
            self.phone_server.server_close()
            self.phone_server = None

    def enable_phone(self, owner, *, ordinary=False):
        if not owner or len(owner) > 128:
            raise ValueError("缺少桌面会话标识。")
        with self.phone_lock:
            workbench = self.context.workbench
            self.phone_ordinary = ordinary
            if ordinary:
                self.tls_generation += 1
                self.tls_job, self.tls_error = "idle", ""
                self._close_setup()
            if self.phone_server and ordinary and self.phone_server.public_scheme == "https":
                with workbench.changed:
                    if workbench.upload or workbench.pending:
                        raise ValueError("照片正在传输，请完成后再切换连接。")
                    self._close_phone_listener()
                    workbench.clear_diagnostics()
            certificate = self.certificate_status(refresh=True)
            if self.phone_server and self.phone_server.public_scheme == "http" and certificate["ready"] and not ordinary:
                with workbench.changed:
                    if workbench.upload or workbench.pending:
                        raise ValueError("照片正在传输，请完成后再开启 HDR 连接。")
                    self._close_phone_listener()
                    workbench.clear_diagnostics()
            if self.phone_server is None:
                self._start_phone(certificate["ready"] and not ordinary)
            with workbench.changed:
                workbench.enabled = True
                workbench.owner = owner
                workbench.desktop_seen = time.monotonic()
                workbench.notify()
            # Existing managed certificates are maintained on connect. Fresh users opt in.
            if not ordinary and certificate["state"] == "renew" and certificate["canPrepare"]:
                self.prepare_phone_tls(owner, setup=False)
            return self.phone_status()

    def open_phone_setup(self, owner):
        from .server import find_free_port
        with self.phone_lock:
            self._require_owner(owner)
            certificate = self.certificate_status(refresh=True)
            if not self.phone_server or self.phone_server.public_scheme != "https" or not certificate["rootAvailable"]:
                raise ValueError("请先准备本机证书，再设置手机。")
            if not self._addresses:
                raise ValueError("请先让电脑连接 Wi-Fi 或以太网。")
            self._close_setup()
            self.setup_server = phone_setup.start(find_free_port("0.0.0.0", 8801),
                                                  self._addresses, self.phone_server, certificate)
            phone_log.log("setup-listener-start", port=self.setup_server.server_port)
            return self.phone_status()

    def _require_owner(self, owner):
        if not self.context.workbench.enabled or owner != self.context.workbench.owner:
            raise ValueError("工作台连接已关闭或被其他窗口接管。")

    def prepare_phone_tls(self, owner, *, setup=True):
        with self.phone_lock:
            self._require_owner(owner)
            if self.tls_job in ("preparing", "waiting"):
                return self.phone_status()
            if not self.certificate_status(refresh=True)["canPrepare"]:
                raise ValueError(self._certificate.get("error") or "自定义证书请由原提供方更新。")
            if not self._addresses:
                raise ValueError("请先让电脑连接 Wi-Fi 或以太网。")
            self.tls_job, self.tls_error = "preparing", ""
            self.phone_ordinary = False
            self.tls_generation += 1
            generation = self.tls_generation

            def prepare():
                try:
                    prepared = phone_tls.prepare(list(self._addresses))
                    if not prepared["ready"]:
                        raise ValueError(prepared.get("error") or "证书未能准备完成，请重试。")
                    while True:
                        with self.phone_lock:
                            workbench = self.context.workbench
                            if generation != self.tls_generation or owner != workbench.owner or not workbench.enabled:
                                return
                            with workbench.changed:
                                # The same lock guards begin_upload, preventing a new upload during the switch.
                                if not workbench.upload and not workbench.pending:
                                    if not self.certificate_status(refresh=True)["ready"]:
                                        raise ValueError("网络地址在配置期间发生变化，请重新准备证书。")
                                    self._close_phone_listener()
                                    self._start_phone(True)
                                    workbench.clear_diagnostics()
                                    if setup:
                                        self.open_phone_setup(owner)
                                    self.tls_job = "idle"
                                    return
                                self.tls_job = "waiting"
                        time.sleep(0.5)
                except (OSError, ValueError, RuntimeError) as error:
                    with self.phone_lock:
                        if generation == self.tls_generation:
                            self.tls_job, self.tls_error = "error", str(error)
                            self._certificate = None

            threading.Thread(target=prepare, daemon=True, name="hyperdr-certificates").start()
            return self.phone_status()

    def stop_phone(self):
        with self.phone_lock:
            self.tls_generation += 1
            self.tls_job, self.tls_error = "idle", ""
            self.context.workbench.disable()
            self._close_phone_listener()
