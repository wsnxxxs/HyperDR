from __future__ import annotations

import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest import mock

from apps.panel.hyperdr_panel.handler import Handler, READ_TIMEOUT_SECONDS
from apps.panel.hyperdr_panel.server import PanelServer


class ServerBoundaryTests(unittest.TestCase):
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
