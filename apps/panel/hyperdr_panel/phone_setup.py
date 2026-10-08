"""Short-lived, certificate-only HTTP onboarding for an HTTPS phone viewer."""
from __future__ import annotations

from http import cookies
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import plistlib
import socket
import threading
import time
from urllib.parse import parse_qs, quote, urlparse
import uuid

from . import phone_tls, security
from .config import WEB_ROOT

SETUP_SECONDS = 15 * 60
COOKIE_NAME = "hyperdr_setup"
ASSETS = {
    "/setup": ("phone/setup.html", "text/html; charset=utf-8"),
    "/phone/setup.js": ("phone/setup.js", "text/javascript; charset=utf-8"),
    # Setup runs before certificate trust, on its own same-origin HTTP listener.
    "/phone/setup.html": ("phone/setup.html", "text/html; charset=utf-8"),
    "/phone/setup-controller.js": ("phone/setup-controller.js", "text/javascript; charset=utf-8"),
    "/js/core/api.js": ("js/core/api.js", "text/javascript; charset=utf-8"),
    "/js/preview/packet.js": ("js/preview/packet.js", "text/javascript; charset=utf-8"),
    "/js/i18n/index.js": ("js/i18n/index.js", "text/javascript; charset=utf-8"),
    "/js/i18n/zh-CN.js": ("js/i18n/zh-CN.js", "text/javascript; charset=utf-8"),
    "/js/i18n/en.js": ("js/i18n/en.js", "text/javascript; charset=utf-8"),
    "/phone/setup.css": ("phone/setup.css", "text/css; charset=utf-8"),
    "/css/tokens.css": ("css/tokens.css", "text/css; charset=utf-8"),
    "/css/base.css": ("css/base.css", "text/css; charset=utf-8"),
    "/icon.svg": ("icon.svg", "image/svg+xml"),
}


class SetupHandler(BaseHTTPRequestHandler):
    server_version = "HyperDR"
    sys_version = ""

    def setup(self):
        super().setup()
        self.connection.settimeout(10)

    def log_message(self, *args):
        pass

    def send(self, status, body=b"", content_type="text/plain; charset=utf-8", **headers):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        for name, value in {**security.SECURITY_HEADERS, **headers}.items():
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if time.monotonic() >= self.server.expires:
            self.send(410, "设置入口已过期，请在电脑上重新点击「设置另一部手机」。".encode())
            return
        parsed = urlparse(self.path)
        token = parse_qs(parsed.query).get("token", [""])[0]
        if parsed.path == "/setup" and token:
            if security.tokens_match(token, self.server.access_token):
                # The QR link may start on another site; its redirect must receive this cookie.
                self.send(303, Location="/setup", **{"Set-Cookie":
                    f"{COOKIE_NAME}={token}; Path=/; HttpOnly; SameSite=Lax; Max-Age={SETUP_SECONDS}"})
            else:
                self.send(403, "设置链接无效，请重新扫码。".encode())
            return
        jar = cookies.SimpleCookie(self.headers.get("Cookie", ""))
        credential = jar.get(COOKIE_NAME)
        if not credential or not security.tokens_match(credential.value, self.server.access_token):
            self.send(401, "请扫描电脑上的首次设置二维码。".encode())
            return
        try:
            # Use only addresses captured by the desktop, never redirect to a supplied Host.
            host = urlparse("http://" + self.headers.get("Host", "")).hostname
            if host not in self.server.addresses:
                self.send(400, "电脑网络地址已改变，请重新扫码。".encode())
                return
            https_url = f"https://{host}:{self.server.phone_port}/phone?token={quote(self.server.phone_token)}&check={quote(self.server.check_token)}"
            if parsed.path == "/setup/state":
                state = self.server.certificate
                payload = {key: state.get(key) for key in (
                    "fingerprint", "certificateName", "expiresAt", "rootAvailable")}
                payload["expiresAt"] = state.get("rootExpiresAt") or state.get("expiresAt")
                payload.update(computer=socket.gethostname(), httpsUrl=https_url,
                               expiresIn=max(0, int(self.server.expires - time.monotonic())))
                self.send(200, json.dumps(payload, ensure_ascii=False).encode(), "application/json; charset=utf-8")
            elif parsed.path == "/setup/continue":
                self.send(303, Location=https_url)
            elif parsed.path in ("/setup/root.crt", "/setup/root.mobileconfig"):
                root = self.server.root_der
                if parsed.path.endswith(".crt"):
                    self.send(200, root, "application/x-x509-ca-cert", **{
                        "Content-Disposition": 'attachment; filename="HyperDR-rootCA.crt"'})
                else:
                    fingerprint = self.server.certificate["fingerprint"]
                    profile_id = str(uuid.uuid5(uuid.NAMESPACE_OID, fingerprint))
                    payload = {"PayloadType": "Configuration", "PayloadVersion": 1,
                               "PayloadIdentifier": "app.hyperdr.phone." + profile_id,
                               "PayloadUUID": profile_id, "PayloadDisplayName": "HyperDR · " + socket.gethostname(),
                               "PayloadDescription": "用于连接你自己的 HyperDR 电脑。安装后请在证书信任设置中开启完全信任。",
                               "PayloadContent": [{"PayloadType": "com.apple.security.root", "PayloadVersion": 1,
                                   "PayloadIdentifier": "app.hyperdr.phone.root." + profile_id,
                                   "PayloadUUID": str(uuid.uuid5(uuid.NAMESPACE_OID, profile_id)),
                                   "PayloadDisplayName": self.server.certificate["certificateName"],
                                   "PayloadContent": root}]}
                    self.send(200, plistlib.dumps(payload), "application/x-apple-aspen-config", **{
                        "Content-Disposition": 'attachment; filename="HyperDR.mobileconfig"'})
            elif parsed.path in ASSETS:
                path, content_type = ASSETS[parsed.path]
                self.send(200, (WEB_ROOT / path).read_bytes(), content_type)
            else:
                self.send(404, b"Not found")
        except (OSError, ValueError) as error:
            self.send(409, json.dumps({"error": str(error)}, ensure_ascii=False).encode(), "application/json; charset=utf-8")

    def do_POST(self):
        self.send(405, b"This listener only serves phone setup.")


def start(port, addresses, phone, certificate):
    # Capture only public data; this listener has no workbench or private-key access route.
    root_der = phone_tls.root_certificate()
    listener = ThreadingHTTPServer(("0.0.0.0", port), SetupHandler)
    listener.daemon_threads = True
    listener.access_token = security.make_token()
    listener.addresses = list(addresses)
    listener.phone_port = phone.server_port
    listener.phone_token = phone.access_token
    listener.check_token = security.make_token()
    phone.setup_check_token = listener.check_token
    listener.certificate = dict(certificate)
    listener.root_der = root_der
    listener.expires = time.monotonic() + SETUP_SECONDS
    threading.Thread(target=listener.serve_forever, daemon=True, name="hyperdr-phone-setup").start()
    listener.timer = threading.Timer(SETUP_SECONDS, lambda: close(listener))
    listener.timer.daemon = True
    listener.timer.start()
    return listener


def close(listener):
    listener.expires = 0
    listener.timer.cancel()
    listener.shutdown()
    listener.server_close()
