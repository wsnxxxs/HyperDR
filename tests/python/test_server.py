from __future__ import annotations

from contextlib import nullcontext
from io import BytesIO
from pathlib import Path
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from types import SimpleNamespace
from urllib.parse import urlparse
from unittest import mock

from apps.panel.hyperdr_panel.handler import Handler, READ_TIMEOUT_SECONDS
from apps.panel.hyperdr_panel import security
from apps.panel.hyperdr_panel.server import PanelServer


class ServerBoundaryTests(unittest.TestCase):
    def _handler(self, cookie: str = "", retry_after: float = 0):
        handler = Handler.__new__(Handler)
        handler.client_address = ("127.0.0.1", 1234)
        handler.headers = {"Cookie": cookie}
        handler.server = SimpleNamespace(
            access_token="secret-token",
            login_throttle=mock.Mock(
                retry_after=mock.Mock(return_value=retry_after),
                record_failure=mock.Mock(),
                clear=mock.Mock(),
            ),
        )
        handler._send = mock.Mock()
        return handler

    def test_login_lands_on_the_panel_root(self):
        handler = Handler.__new__(Handler)
        handler.client_address = ("127.0.0.1", 1234)
        handler.server = SimpleNamespace(
            access_token="secret-token",
            cookie_secure=False,
            login_throttle=mock.Mock(
                retry_after=mock.Mock(return_value=0),
                clear=mock.Mock(),
            ),
        )
        handler.send_response = mock.Mock()
        handler.send_header = mock.Mock()
        handler.end_headers = mock.Mock()

        self.assertTrue(handler._accept_login(urlparse("/?token=secret-token")))
        handler.send_response.assert_called_once_with(303)
        self.assertIn(
            mock.call("Location", "/"),
            handler.send_header.call_args_list,
        )

    def test_handler_sets_read_timeout_on_accepted_socket(self):
        handler = Handler.__new__(Handler)
        handler.connection = mock.Mock()
        with mock.patch.object(BaseHTTPRequestHandler, "setup"):
            Handler.setup(handler)
        handler.connection.settimeout.assert_called_once_with(READ_TIMEOUT_SECONDS)

    def test_missing_cookie_is_not_counted_as_a_failed_guess(self):
        handler = self._handler()

        self.assertFalse(handler._require_authorized())
        handler.server.login_throttle.retry_after.assert_not_called()
        handler.server.login_throttle.record_failure.assert_not_called()
        self.assertEqual(handler._send.call_args.args[0].status, 401)

    def test_invalid_cookie_is_counted_as_a_failed_guess(self):
        handler = self._handler("hyperdr_access=wrong")

        self.assertFalse(handler._require_authorized())
        handler.server.login_throttle.retry_after.assert_called_once_with("127.0.0.1")
        handler.server.login_throttle.record_failure.assert_called_once_with("127.0.0.1")
        self.assertEqual(handler._send.call_args.args[0].status, 401)

    def test_cookie_guess_is_refused_during_lockout(self):
        handler = self._handler("hyperdr_access=wrong", retry_after=4.2)

        self.assertFalse(handler._require_authorized())
        handler.server.login_throttle.record_failure.assert_not_called()
        response = handler._send.call_args.args[0]
        self.assertEqual(response.status, 429)
        self.assertEqual(response.headers["Retry-After"], "5")

    def test_valid_cookie_clears_failures(self):
        handler = self._handler("hyperdr_access=secret-token")

        self.assertTrue(handler._require_authorized())
        handler.server.login_throttle.clear.assert_called_once_with("127.0.0.1")
        handler._send.assert_not_called()

    def test_valid_cookie_is_accepted_during_an_ip_lockout(self):
        handler = self._handler("hyperdr_access=secret-token", retry_after=4.2)

        self.assertTrue(handler._require_authorized())
        handler.server.login_throttle.retry_after.assert_not_called()
        handler.server.login_throttle.clear.assert_called_once_with("127.0.0.1")

    def test_non_ascii_credentials_fail_without_raising(self):
        self.assertFalse(security.tokens_match("é", "secret-token"))

    def test_generated_tokens_have_128_bits_of_entropy(self):
        token = security.make_token()
        self.assertEqual(len(token), 22)
        self.assertEqual(security.check_token_format(token), token)

    def test_upload_name_is_url_decoded_once(self):
        handler = self._handler("hyperdr_access=secret-token")
        handler.path = "/api/upload?id=session&name=a%2520b.jpg"
        handler.headers["Content-Length"] = "0"
        handler.rfile = BytesIO()
        with mock.patch(
            "apps.panel.hyperdr_panel.handler.api.upload_is_allowed",
            return_value=nullcontext(),
        ), mock.patch(
            "apps.panel.hyperdr_panel.handler.save_upload",
            return_value=(Path("a%20b.jpg"), 0),
        ) as save:
            handler._handle_upload()

        self.assertEqual(save.call_args.args[1], "a%20b.jpg")
        self.assertEqual(handler._send.call_args.args[0].status, 201)

    def test_connection_limit_returns_503_without_starting_thread(self):
        server = PanelServer.__new__(PanelServer)
        server.connection_slots = threading.BoundedSemaphore(1)
        self.assertTrue(server.connection_slots.acquire(blocking=False))
        request = mock.Mock()
        with mock.patch.object(ThreadingHTTPServer, "process_request") as process:
            server.process_request(request, ("127.0.0.1", 1234))
        process.assert_not_called()
        request.sendall.assert_called_once()
        self.assertIn(b"503 Service Unavailable", request.sendall.call_args.args[0])
        request.close.assert_called_once_with()
        server.connection_slots.release()

    def test_worker_releases_connection_slot(self):
        server = PanelServer.__new__(PanelServer)
        server.connection_slots = threading.BoundedSemaphore(1)
        self.assertTrue(server.connection_slots.acquire(blocking=False))
        with mock.patch.object(ThreadingHTTPServer, "process_request_thread"):
            server.process_request_thread(mock.Mock(), ("127.0.0.1", 1234))
        self.assertTrue(server.connection_slots.acquire(blocking=False))
        server.connection_slots.release()


if __name__ == "__main__":
    unittest.main()
