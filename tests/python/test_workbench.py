"""Phone handoff and the dedicated viewer's real HTTP contract."""
from __future__ import annotations

from io import BytesIO
import http.client
import json
from pathlib import Path
import tempfile
import threading
import time
import unittest
from unittest import mock

from apps.panel.hyperdr_panel import session, server
from apps.panel.hyperdr_panel.workbench import Workbench


class WorkbenchTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        patch = mock.patch.object(session, "WORK_ROOT", Path(self.temp.name))
        patch.start()
        self.addCleanup(patch.stop)
        self.workbench = Workbench()
        self.workbench.enabled = True
        self.workbench.owner = "desktop"
        self.workbench.desktop_seen = time.monotonic()

    def photo(self):
        sid = session.create_session()
        # JPEG signature is enough for intake; pixel decoding belongs to the renderer.
        session.save_upload(sid, "photo.jpg", BytesIO(b"\xff\xd8\xffphoto"), 8)
        return sid

    def publish(self, sid, **kwargs):
        return self.workbench.publish({"owner": "desktop", "current": {
            "sessionId": sid, "options": {"brightness": 0.6}, **kwargs}})

    def test_phone_upload_survives_stale_desktop_publish_until_adopted(self):
        old = self.photo()
        self.publish(old)
        new = self.workbench.begin_upload("new.jpg")["sessionId"]
        session.save_upload(new, "new.jpg", BytesIO(b"\xff\xd8\xffnew"), 6)
        self.workbench.update_upload({"sessionId": new, "complete": True})
        stale = self.publish(old)
        self.assertEqual(stale["pending"], new)
        self.assertEqual(stale["current"]["sessionId"], new)
        adopted = self.publish(new)
        self.assertEqual(adopted["pending"], "")
        self.assertEqual(adopted["current"]["file"]["name"], "new.jpg")

    def test_preview_is_visible_only_for_current_photo_and_settings(self):
        sid = self.photo()
        self.publish(sid)
        self.workbench.publish_frame(sid, {"brightness": 0.6}, b"native frame")
        self.assertTrue(self.workbench.snapshot()["frameReady"])
        self.publish(sid, options={"brightness": 1.2})
        self.assertFalse(self.workbench.snapshot()["frameReady"])
        self.workbench.publish_frame(sid, {"brightness": 1.2}, b"new frame")
        self.assertTrue(self.workbench.snapshot()["frameReady"])
        self.assertEqual(self.workbench.original_frame[2], b"native frame")
        # Fast cached rendering may arrive before the state POST.
        self.workbench.publish_frame(sid, {"brightness": 1.3}, b"cached frame")
        self.publish(sid, options={"brightness": 1.3})
        self.assertEqual(self.workbench.frame[2], b"cached frame")
        self.assertTrue(self.workbench.snapshot()["frameReady"])
        self.publish(self.photo())
        self.assertFalse(self.workbench.snapshot()["frameReady"])

    def test_cancel_keeps_current_photo_and_busy_editor_refuses_replacement(self):
        sid = self.photo()
        self.publish(sid)
        upload = self.workbench.begin_upload("new.jpg")
        self.workbench.update_upload({**upload, "cancel": True})
        self.assertEqual(self.workbench.snapshot()["current"]["sessionId"], sid)
        self.publish(sid, busy=True)
        with self.assertRaises(ValueError):
            self.workbench.begin_upload("new.jpg")

    def test_phone_http_exposes_viewer_and_upload_but_no_editor_commands(self):
        phone = server.build_server("127.0.0.1", 0, "phone-test-token", "http", phone_only=True)
        phone.context.workbench = self.workbench
        thread = threading.Thread(target=phone.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(phone.server_close)
        self.addCleanup(phone.shutdown)

        def call(method, path, body=None):
            connection = http.client.HTTPConnection("127.0.0.1", phone.server_port, timeout=2)
            headers = {"Cookie": "hyperdr_access=phone-test-token"}
            if body is not None:
                headers["Content-Type"] = "application/json"
            connection.request(method, path, json.dumps(body) if body is not None else None, headers)
            response = connection.getresponse()
            result = response.status, response.read()
            connection.close()
            return result

        status, html = call("GET", "/phone")
        self.assertEqual(status, 200)
        self.assertIn(b"/phone/app.js", html)
        self.assertNotIn(b"js/main.js", html)
        self.assertEqual(call("POST", "/api/native-input", {"path": "C:/private.jpg"})[0], 404)
        self.assertEqual(call("POST", "/api/run", {})[0], 404)
        self.assertEqual(call("POST", "/api/phone/connect", {"owner": "intruder"})[0], 403)
        self.assertEqual(call("GET", "/api/result?id=unshared&export=result")[0], 404)
        status, body = call("POST", "/api/phone/import", {"name": "phone.jpg"})
        self.assertEqual(status, 200)
        self.assertTrue(json.loads(body)["sessionId"])

    def test_replaced_desktop_cannot_change_current_photo(self):
        with self.assertRaises(ValueError):
            self.workbench.publish({"owner": "old-window", "current": {}})
        self.workbench.disable()
        self.assertFalse(self.workbench.snapshot()["enabled"])
        self.assertIsNone(self.workbench.frame)


if __name__ == "__main__":
    unittest.main()
