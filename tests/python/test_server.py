from __future__ import annotations

import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from types import SimpleNamespace
from urllib.parse import urlparse
from unittest import mock

from apps.panel.hyperdr_panel.handler import Handler, READ_TIMEOUT_SECONDS
from apps.panel.hyperdr_panel.server import PanelServer


class ServerBoundaryTests(unittest.TestCase):
    def test_login_lands_on_the_panel_root(self):
        handler = Handler.__new__(Handler)
        handler.client_address = ("127.0.0.1", 1234)
        handler.server = SimpleNamespace(
            access_token="secret",
            cookie_secure=False,
            login_throttle=mock.Mock(
                retry_after=mock.Mock(return_value=0),
                clear=mock.Mock(),
            ),
        )
        handler.send_response = mock.Mock()
        handler.send_header = mock.Mock()
        handler.end_headers = mock.Mock()

        self.assertTrue(handler._accept_login(urlparse("/?token=secret")))
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
