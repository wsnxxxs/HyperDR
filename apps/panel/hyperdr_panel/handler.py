"""The HTTP mechanics: authentication, routing, and sending bytes.

Everything here needs a live connection. The endpoints themselves live in
`api.py` as plain functions, so this file stays small enough to audit as
security-relevant code.
"""
from __future__ import annotations

import json
import os
import time
from http import cookies
from http.server import BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import parse_qs, quote, urlparse

from . import api, job, security
from .config import WEB_ROOT
from .session import save_upload

_CONTENT_TYPES = {
    ".html": "text/html; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".js": "text/javascript; charset=utf-8",
    ".mjs": "text/javascript; charset=utf-8",
    ".png": "image/png",
    ".svg": "image/svg+xml",
    ".ico": "image/x-icon",
    ".json": "application/json; charset=utf-8",
}

_JSON = "application/json; charset=utf-8"
# A request body is settings, never image data; uploads stream through their own
# path and are bounded separately.
MAX_BODY_BYTES = 1024 * 1024
READ_TIMEOUT_SECONDS = max(1, int(os.environ.get("HYPERDR_READ_TIMEOUT_SECONDS", "30")))


class Handler(BaseHTTPRequestHandler):
    server_version = "HyperDR"
    sys_version = ""

    def setup(self):
        super().setup()
        self.connection.settimeout(READ_TIMEOUT_SECONDS)

    def handle_one_request(self):
        try:
            super().handle_one_request()
        except TimeoutError:
            self.close_connection = True

    def log_message(self, fmt, *args):
        if os.environ.get("HYPERDR_HTTP_LOG") == "1":
            super().log_message(fmt, *args)

    # -- authentication ------------------------------------------------- #
    def _cookie_token(self) -> str:
        jar = cookies.SimpleCookie(self.headers.get("Cookie", ""))
        value = jar.get(security.COOKIE_NAME)
        return value.value if value else ""

    def _lockout_response(self, retry_after: float) -> api.Response:
        return api.Response(
            status=429,
            payload={"error": "尝试次数过多，请稍后再试。",
                     "code": "too_many_attempts"},
            headers={"Retry-After": str(int(retry_after) + 1)},
        )

    def _accept_login(self, parsed) -> bool:
        """Exchange ?token=... for a cookie. True when the request was handled."""
        supplied = parse_qs(parsed.query).get("token", [""])[0]
        if parsed.path not in ("/", "/phone", "/phone/") or not supplied:
            return False
        client_ip = self.client_address[0]
        if security.tokens_match(supplied, self.server.access_token):
            self.server.login_throttle.clear(client_ip)
            self.send_response(303)
            self.send_header("Location", "/phone" if parsed.path.startswith("/phone") or getattr(self.server, "phone_only", False) else "/")
            self.send_header("Set-Cookie", security.cookie_attributes(
                self.server.access_token, self.server.cookie_secure))
            for name, value in security.SECURITY_HEADERS.items():
                self.send_header(name, value)
            self.end_headers()
            return True
        retry_after = self.server.login_throttle.retry_after(client_ip)
        if retry_after > 0:
            self._send(self._lockout_response(retry_after))
            return True
        self.server.login_throttle.record_failure(client_ip)
        self._send(api.Response(status=403, payload={
            "error": "访问口令无效。", "code": "token_invalid"}))
        return True

    def _require_authorized(self) -> bool:
        supplied = self._cookie_token()
        if not supplied:
            self._send(api.Response(status=401, payload={
                "error": "需要访问口令。请使用启动窗口显示的完整地址。",
            "code": "token_required"}))
            return False

        client_ip = self.client_address[0]
        if security.tokens_match(supplied, self.server.access_token):
            self.server.login_throttle.clear(client_ip)
            return True
        retry_after = self.server.login_throttle.retry_after(client_ip)
        if retry_after > 0:
            self._send(self._lockout_response(retry_after))
            return False
        self.server.login_throttle.record_failure(client_ip)
        self._send(api.Response(status=401, payload={
            "error": "需要访问口令。请使用启动窗口显示的完整地址。",
            "code": "token_required"}))
        return False

    def _same_origin(self) -> bool:
        origin = self.headers.get("Origin")
        if not origin:
            return True
        return urlparse(origin).netloc.lower() == self.headers.get("Host", "").lower()

    # -- sending -------------------------------------------------------- #
    def _common_headers(self) -> None:
        for name, value in security.SECURITY_HEADERS.items():
            self.send_header(name, value)
        if self.server.public_scheme == "https":
            self.send_header("Strict-Transport-Security", "max-age=86400")

    def _send(self, response: api.Response) -> None:
        if response.file is not None:
            self._send_file(response)
            return
        if response.body is not None:
            data, content_type = response.body, response.content_type
        else:
            data = json.dumps(response.payload, ensure_ascii=False).encode("utf-8")
            content_type = _JSON
        self.send_response(response.status)
        self.send_header("Content-Type", content_type or "application/octet-stream")
        self.send_header("Content-Length", str(len(data)))
        self._common_headers()
        for name, value in response.headers.items():
            self.send_header(name, str(value))
        self.end_headers()
        self.wfile.write(data)

    def _send_file(self, response: api.Response) -> None:
        target = response.file
        disposition = "attachment" if response.download else "inline"
        # Both forms: the ASCII fallback for old clients, the UTF-8 form for the
        # actual name, which is routinely non-ASCII here.
        ascii_name = "hyperdr-result" + target.suffix.lower()
        self.send_response(response.status)
        self.send_header("Content-Type", response.content_type or "application/octet-stream")
        self.send_header("Content-Length", str(target.stat().st_size))
        self.send_header("Content-Disposition",
                         f"{disposition}; filename={ascii_name}; "
                         f"filename*=UTF-8''{quote(target.name)}")
        self._common_headers()
        self.end_headers()
        with target.open("rb") as source:
            while chunk := source.read(1024 * 1024):
                self.wfile.write(chunk)

    def _serve_from(self, root: Path, relative: str) -> bool:
        """Send a file below `root`, refusing anything that escapes it."""
        try:
            target = (root / relative).resolve()
            target.relative_to(root.resolve())
        except (ValueError, OSError):
            return False
        if not target.is_file():
            return False
        self._send(api.Response(
            body=target.read_bytes(),
            content_type=_CONTENT_TYPES.get(target.suffix.lower(),
                                            "application/octet-stream")))
        return True

    def _serve_static(self, route: str) -> bool:
        if route in ("/phone", "/phone/") or (route in ("/", "/index.html") and self.server.phone_only):
            return self._serve_from(WEB_ROOT, "phone/index.html")
        relative = "index.html" if route in ("/", "/index.html") else route.lstrip("/")
        return self._serve_from(WEB_ROOT, relative)

    def _read_json(self) -> dict:
        length = int(self.headers.get("Content-Length", "0"))
        if length < 0 or length > MAX_BODY_BYTES:
            oversize = ValueError("请求内容过大。")
            oversize.code = "body_too_large"
            raise oversize
        body = json.loads(self.rfile.read(length) or b"{}")
        # `json.loads` returns whatever the document is, and every route then
        # calls `body.get(...)`. A perfectly valid `[]` therefore raised
        # AttributeError out of the route, which nothing caught: the client saw
        # the connection drop instead of a 400.
        if not isinstance(body, dict):
            raise ValueError("请求体必须是 JSON 对象。")
        return body

    # -- routing -------------------------------------------------------- #
    def do_GET(self):
        parsed = urlparse(self.path)
        if self._accept_login(parsed):
            return
        if not self._require_authorized():
            return
        if parsed.path.startswith("/api/phone/"):
            self._phone_get(parsed)
            return
        if self.server.phone_only and parsed.path.startswith("/api/"):
            if parsed.path not in ("/api/state", "/api/result"):
                self._send(api.error("not found", status=404))
                return
            if parsed.path == "/api/result":
                query = parse_qs(parsed.query)
                allowed = any(e["sessionId"] == api._first(query, "id") and e["id"] == api._first(query, "export")
                              for e in self.server.context.workbench.snapshot()["completed"])
                if not allowed:
                    self._send(api.error("结果尚未分享到手机。", status=404))
                    return
        route = api.GET_ROUTES.get(parsed.path)
        if route is not None:
            self._send(self._dispatch(route, parse_qs(parsed.query)))
            return
        if parsed.path.startswith("/api/"):
            self._send(api.error("not found", status=404))
            return
        if not self._serve_static(parsed.path):
            self._send(api.error("not found", status=404))

    def do_POST(self):
        if not self._require_authorized():
            return
        if not self._same_origin():
            self._send(api.error("请求来源不匹配。", status=403,
                                 code="origin_mismatch"))
            return
        path = urlparse(self.path).path
        if self.server.phone_only and path != "/api/upload" and not path.startswith("/api/phone/"):
            self._send(api.error("not found", status=404))
            return
        if path == "/api/upload":
            self._handle_upload()
            return
        route = self._phone_post if path.startswith("/api/phone/") else api.POST_ROUTES.get(path)
        if route is None:
            self._send(api.error("not found", status=404))
            return
        try:
            body = self._read_json()
        except (ValueError, json.JSONDecodeError) as exc:
            self._send(api.error(exc))
            return
        self._send(self._dispatch(route, body))

    def _phone_get(self, parsed):
        workbench = self.server.context.workbench
        if parsed.path == "/api/phone/state":
            if self.server.phone_only:
                workbench.phone_seen = time.monotonic()
            self._send(api.Response(payload=workbench.snapshot()))
        elif parsed.path in ("/api/phone/frame", "/api/phone/original"):
            with workbench.changed:
                original = parsed.path.endswith("/original")
                frame = workbench.original_frame if original else workbench.frame
                version = workbench.frame_version
                key = (workbench.current.get("sessionId"), workbench.current.get("options", {}).get("highlightRecovery", "blend")) if original else workbench.frame_key()
                if not frame or frame[:2] != key:
                    self._send(api.error("正在更新预览。", status=409))
                    return
            self._send(api.Response(body=frame[2], content_type="application/vnd.hyperdr.preview",
                                    headers={"X-Frame-Version": str(version)}))
        elif parsed.path == "/api/phone/events" and self.server.phone_only:
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self._common_headers()
            self.end_headers()
            self.close_connection = True
            revision = -1
            try:
                while workbench.enabled:
                    with workbench.changed:
                        workbench.phone_seen = time.monotonic()
                        if revision == workbench.revision:
                            workbench.changed.wait(timeout=5)
                        payload = workbench.snapshot()
                        revision = payload["revision"]
                    data = json.dumps(payload, ensure_ascii=False)
                    self.wfile.write(f"data: {data}\n\n".encode("utf-8"))
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionError, TimeoutError):
                pass
        else:
            self._send(api.error("not found", status=404))

    def _phone_post(self, context, body):
        path = urlparse(self.path).path
        workbench = context.workbench
        desktop_routes = ("/api/phone/connect", "/api/phone/disconnect", "/api/phone/publish", "/api/phone/heartbeat")
        if path in desktop_routes and (self.server.phone_only or self.client_address[0] not in ("127.0.0.1", "::1")):
            return api.error("请在电脑编辑器中管理连接。", status=403)
        if path in desktop_routes[1:] and body.get("owner") != workbench.owner:
            return api.error("工作台连接已关闭或被其他窗口接管。", status=409,
                             code="workbench_owner")
        try:
            if path == "/api/phone/heartbeat":
                workbench.desktop_seen = time.monotonic()
                return api.Response(payload={"enabled": workbench.enabled})
            if path == "/api/phone/connect":
                return api.Response(payload=self.server.enable_phone(str(body.get("owner", ""))))
            if path == "/api/phone/disconnect":
                self.server.stop_phone()
                return api.Response(payload={"enabled": False})
            if path == "/api/phone/publish":
                return api.Response(payload=workbench.publish(body))
            if path == "/api/phone/import":
                return api.Response(payload=workbench.begin_upload(body.get("name", "")))
            if path == "/api/phone/upload":
                return api.Response(payload=workbench.update_upload(body))
        except (ValueError, OSError) as exc:
            return api.error(exc, status=409)
        return api.error("not found", status=404)

    def _dispatch(self, route, argument) -> api.Response:
        """Run an endpoint, turning any escaping exception into a response.

        Endpoints catch the errors they expect. Anything they do not is still a
        request that deserves an answer: without this the exception propagated
        out of the handler, the server logged a traceback, and the browser saw
        `RemoteDisconnected` with nothing to display.
        """
        try:
            return route(self.server.context, argument)
        except Exception as exc:  # noqa: BLE001 - the boundary is the point
            if os.environ.get("HYPERDR_HTTP_LOG") == "1":
                import traceback
                traceback.print_exc()
            return api.error("请求处理失败：%s" % exc, status=500)

    def _handle_upload(self):
        """Streamed rather than buffered: an upload is up to a few hundred MB."""
        query = parse_qs(urlparse(self.path).query)
        session_id = query.get("id", [""])[0]
        filename = query.get("name", [""])[0]
        if getattr(self.server, "phone_only", False):
            upload = self.server.context.workbench.snapshot()["upload"]
            if not upload or upload["sessionId"] != session_id:
                self.close_connection = True
                self._send(api.error("请先选择要导入的照片。", status=409))
                return
        try:
            with job.upload_slot():
                length = int(self.headers.get("Content-Length", "0"))
                target, written = save_upload(session_id, filename, self.rfile, length)
        except (job.Busy, OSError, ValueError) as exc:
            # The body may be unread, so the connection cannot be reused.
            self.close_connection = True
            self._send(api.error(exc))
            return
        self._send(api.Response(status=201, payload={"name": target.name, "bytes": written}))
