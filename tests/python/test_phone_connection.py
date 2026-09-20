"""Real HTTP/TLS checks for desktop-managed phone onboarding."""
from io import BytesIO
import http.client
import json
import os
from pathlib import Path
import plistlib
import ssl
import tempfile
import threading
import time
import unittest
from unittest import mock

from cryptography import x509
from cryptography.hazmat.primitives import serialization
from apps.panel.hyperdr_panel import phone_tls, server, session


class PhoneConnectionTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        environment = dict(os.environ, LOCALAPPDATA=temporary.name)
        for name in ("HYPERDR_TLS_CERT", "HYPERDR_TLS_KEY", "CAROOT", "HYPERDR_COOKIE_SECURE"):
            environment.pop(name, None)
        for patcher in (
            mock.patch.dict(os.environ, environment, clear=True),
            mock.patch.object(session, "WORK_ROOT", Path(temporary.name) / "work"),
            mock.patch.object(server, "lan_addresses", return_value=["127.0.0.1"]),
            mock.patch.object(server, "find_free_port", return_value=0),
        ):
            patcher.start()
            self.addCleanup(patcher.stop)
        self.desktop = server.build_server("127.0.0.1", 0, "desktop-test-token", "http", desktop=True)
        threading.Thread(target=self.desktop.serve_forever, daemon=True).start()
        self.addCleanup(self.desktop.server_close)
        self.addCleanup(self.desktop.shutdown)
        self.addCleanup(self.desktop.stop_phone)
        code, _, _ = self.call(self.desktop, "POST", "/api/phone/connect", {"owner": "desktop"})
        self.assertEqual(code, 200)

    def call(self, listener, method, path, body=None, *, cookie=None):
        if getattr(listener, "public_scheme", "http") == "https":
            root = x509.load_der_x509_certificate(phone_tls.root_certificate())
            context = ssl.create_default_context(cadata=root.public_bytes(serialization.Encoding.PEM).decode())
            connection = http.client.HTTPSConnection("127.0.0.1", listener.server_port, context=context, timeout=4)
        else:
            connection = http.client.HTTPConnection("127.0.0.1", listener.server_port, timeout=4)
        headers = {"Cookie": cookie if cookie is not None else "hyperdr_access=" + listener.access_token}
        data = None if body is None else json.dumps(body).encode()
        if data is not None:
            headers["Content-Type"] = "application/json"
        try:
            connection.request(method, path, body=data, headers=headers)
            response = connection.getresponse()
            return response.status, dict(response.getheaders()), response.read()
        finally:
            connection.close()

    def wait_for(self, predicate):
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            if predicate():
                return
            if self.desktop.tls_job == "error":
                self.fail(self.desktop.tls_error)
            time.sleep(0.05)
        self.fail("Phone certificate worker did not converge")

    def prepare(self):
        code, _, _ = self.call(self.desktop, "POST", "/api/phone/tls/prepare", {"owner": "desktop"})
        self.assertEqual(code, 202)
        self.wait_for(lambda: self.desktop.tls_job == "idle")
        self.assertEqual(self.desktop.phone_server.public_scheme, "https")

    def test_authenticated_prepare_is_async_and_serves_verified_https(self):
        self.assertEqual(self.call(self.desktop, "POST", "/api/phone/tls/prepare", {"owner": "desktop"}, cookie="")[0], 401)
        self.assertEqual(self.call(self.desktop, "POST", "/api/phone/tls/prepare", {"owner": "other"})[0], 409)
        release = threading.Event()
        actual = phone_tls.prepare

        def delayed(addresses):
            release.wait(10)
            return actual(addresses)

        with mock.patch.object(phone_tls, "prepare", side_effect=delayed):
            try:
                code, _, payload = self.call(self.desktop, "POST", "/api/phone/tls/prepare", {"owner": "desktop"})
                self.assertEqual(code, 202)
                self.assertEqual(json.loads(payload)["tls"]["job"], "preparing")
            finally:
                release.set()
            self.wait_for(lambda: self.desktop.tls_job == "idle")
        self.assertEqual(self.call(self.desktop.phone_server, "GET", "/api/phone/state")[0], 200)

    def test_setup_only_exposes_authenticated_public_certificate_and_expires(self):
        self.prepare()
        setup = self.desktop.setup_server
        self.assertEqual(self.call(setup, "GET", "/setup/root.crt", cookie="")[0], 401)
        code, headers, _ = self.call(setup, "GET", "/setup?token=" + setup.access_token, cookie="")
        self.assertEqual(code, 303)
        cookie = headers["Set-Cookie"].split(";", 1)[0]
        code, _, root = self.call(setup, "GET", "/setup/root.crt", cookie=cookie)
        self.assertEqual(code, 200)
        self.assertEqual(root, phone_tls.root_certificate())
        self.assertTrue(x509.load_der_x509_certificate(root).extensions.get_extension_for_class(x509.BasicConstraints).value.ca)
        code, _, profile = self.call(setup, "GET", "/setup/root.mobileconfig", cookie=cookie)
        self.assertEqual(code, 200)
        content = plistlib.loads(profile)["PayloadContent"]
        self.assertEqual(len(content), 1)
        self.assertEqual(content[0]["PayloadType"], "com.apple.security.root")
        self.assertEqual(content[0]["PayloadContent"], root)
        for path in ("/api/state", "/api/phone/state", "/hyperdr-key.pem", "/setup/../ca/rootCA-key.pem"):
            self.assertEqual(self.call(setup, "GET", path, cookie=cookie)[0], 404)
        self.assertEqual(self.call(setup, "POST", "/api/phone/import", {"name": "photo.jpg"}, cookie=cookie)[0], 405)
        self.assertEqual(self.call(setup, "GET", "/setup/continue", cookie=cookie)[1]["Location"].split(":", 1)[0], "https")
        setup.expires = time.monotonic() - 1
        self.assertEqual(self.call(setup, "GET", "/setup/root.crt", cookie=cookie)[0], 410)
        self.assertEqual(self.desktop.phone_status()["setupUrls"], [])

    def test_diagnostics_require_real_https_before_closing_setup(self):
        report = dict(secureContext=True, webgpu=True, displayHdr=True, hdr=True, reason="ready")
        code, _, payload = self.call(self.desktop.phone_server, "POST", "/api/phone/diagnostics", report)
        self.assertEqual(code, 200)
        self.assertFalse(json.loads(payload)["diagnostics"]["secureContext"])
        self.assertFalse(json.loads(payload)["diagnostics"]["hdr"])
        self.prepare()
        self.assertIsNotNone(self.desktop.setup_server)
        # An already connected viewer must not close setup for a different phone.
        code, _, payload = self.call(self.desktop.phone_server, "POST", "/api/phone/diagnostics", report)
        self.assertIsNotNone(self.desktop.setup_server)
        check = self.desktop.setup_server.check_token
        code, headers, _ = self.call(self.desktop.phone_server, "GET",
                                    "/phone?token=" + self.desktop.phone_server.access_token + "&check=" + check)
        self.assertEqual(headers["Location"], "/phone?check=" + check)
        code, _, payload = self.call(self.desktop.phone_server, "POST", "/api/phone/diagnostics", {**report, "setupCheck": check})
        self.assertEqual(code, 200)
        self.assertTrue(json.loads(payload)["diagnostics"]["hdr"])
        self.assertIsNone(self.desktop.setup_server)
        self.assertEqual(self.call(self.desktop, "POST", "/api/phone/diagnostics", report)[0], 403)

    def test_renewal_waits_for_upload_and_preserves_photo_and_root(self):
        self.prepare()
        workbench = self.desktop.context.workbench
        sid = session.create_session()
        session.save_upload(sid, "photo.jpg", BytesIO(b"\xff\xd8\xffphoto"), 8)
        workbench.publish({"owner": "desktop", "current": {"sessionId": sid, "options": {"brightness": 0.6}}})
        workbench.publish_frame(sid, {"brightness": 0.6}, b"rendered frame")
        before = workbench.snapshot()["current"]
        root = phone_tls.root_certificate()
        original_listener = self.desktop.phone_server
        upload = workbench.begin_upload("replacement.jpg")
        with mock.patch.object(server, "lan_addresses", return_value=["127.0.0.1", "127.0.0.2"]):
            code, _, _ = self.call(self.desktop, "POST", "/api/phone/tls/prepare", {"owner": "desktop"})
            self.assertEqual(code, 202)
            self.wait_for(lambda: self.desktop.tls_job == "waiting")
            self.assertIs(self.desktop.phone_server, original_listener)
            workbench.update_upload({**upload, "cancel": True})
            self.wait_for(lambda: self.desktop.tls_job == "idle")
            self.assertTrue(phone_tls.status(["127.0.0.2"])["ready"])
        self.assertIs(self.desktop.phone_server.context.workbench, workbench)
        self.assertEqual(workbench.snapshot()["current"], before)
        self.assertEqual(workbench.frame[2], b"rendered frame")
        self.assertEqual(root, phone_tls.root_certificate())
        self.assertIsNot(self.desktop.phone_server, original_listener)
        self.assertEqual(self.call(self.desktop.phone_server, "GET", "/api/phone/state")[0], 200)

    def test_loopback_editor_does_not_require_phone_root_trust(self):
        self.prepare()
        certificate, key = phone_tls.paths()
        editor = mock.Mock()
        editor.serve_forever.side_effect = KeyboardInterrupt
        with (mock.patch.dict(os.environ, HYPERDR_HOST="127.0.0.1", HYPERDR_TLS_CERT=str(certificate), HYPERDR_TLS_KEY=str(key)),
              mock.patch.object(server, "build_server", return_value=editor) as build,
              mock.patch.object(server, "load_tls_context") as tls,
              mock.patch.object(server, "cleanup_expired_sessions", return_value=[]),
              mock.patch.object(server, "shutdown")):
            server.serve(desktop=True)
            self.assertEqual(build.call_args.args[3], "http")
            tls.assert_not_called()


if __name__ == "__main__":
    unittest.main()
