"""Exercise the export lifecycle across session, API and job boundaries."""
import io
import json
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

from apps.panel.hyperdr_panel import api, job, renditions, session


class RenditionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = mock.patch.object(session, "WORK_ROOT", Path(self.temp.name))
        self.root.start()
        self.sid = session.create_session()
        data = b"\x89PNG\r\n\x1a\n" + b"x" * 64
        session.save_upload(self.sid, "photo.png", io.BytesIO(data), len(data))
        self.context = api.Context()

    def tearDown(self):
        self.root.stop()
        self.temp.cleanup()
        with job._LOCK:
            job._JOB = None

    def complete(self, name="photo.heic", content=b"first"):
        rid, folder = renditions.prepare(self.sid, {"encoding": "adaptive"})
        target = folder / name
        target.write_bytes(content)
        report = {"files": [{"success": True, "output": str(target)}]}
        return renditions.publish(self.sid, rid, report)

    def test_retry_and_failure_preserve_previous_download(self):
        first = self.complete()
        pending, folder = renditions.prepare(self.sid, {})
        (folder / "photo.avif").write_bytes(b"partial")
        self.assertEqual(renditions.result_path(self.sid).read_bytes(), b"first")
        renditions.discard(self.sid, pending)
        self.assertFalse(folder.exists())
        response = api.result(self.context, {"id": [self.sid], "export": [first["id"]]})
        self.assertEqual(response.file.read_bytes(), b"first")

    def test_versions_have_stable_downloads_and_survive_memory_reset(self):
        first = self.complete()
        second = self.complete("photo.avif", b"second")
        session._INPUT_PATHS.clear()
        session._INPUT_DIGESTS.clear()
        self.assertEqual(renditions.result_path(self.sid).read_bytes(), b"second")
        self.assertEqual(renditions.result_path(self.sid, first["id"]).read_bytes(), b"first")
        state = api.workspace(self.context, {"id": [self.sid]}).payload
        self.assertEqual(state["file"]["name"], "photo.png")
        self.assertEqual([entry["id"] for entry in state["exports"]], [second["id"], first["id"]])

    def test_invalid_settings_leave_existing_result_untouched(self):
        first = self.complete()
        with mock.patch.object(api, "detect_exe", return_value="HyperDR"):
            response = api.run(self.context, {"sessionId": self.sid,
                "options": {"modelStrength": 3}})
        self.assertEqual(response.status, 400)
        self.assertEqual(renditions.list_for(self.sid)[0]["id"], first["id"])

    def test_missing_or_failed_report_cannot_publish_a_result(self):
        rid, folder = renditions.prepare(self.sid, {})
        for report in (None, {}, {"files": [{"success": False}]}):
            with self.assertRaises(ValueError):
                renditions.publish(self.sid, rid, report)
        self.assertEqual(renditions.list_for(self.sid), [])

    def test_report_cannot_publish_a_file_outside_its_export(self):
        rid, folder = renditions.prepare(self.sid, {})
        outside = folder.parent / "other.heic"
        outside.write_bytes(b"other")
        with self.assertRaises(ValueError):
            renditions.publish(self.sid, rid, {"files": [{"success": True, "output": str(outside)}]})

    def test_job_publishes_before_reporting_done(self):
        rid, folder = renditions.prepare(self.sid, {})
        target = folder / "photo.heic"
        target.write_bytes(b"converted")
        report_path = folder / "report.json"
        report_path.write_text(json.dumps({"files": [{"success": True, "output": str(target)}]}))
        process = mock.Mock(stdout=iter(["converted\n"]), returncode=0)
        with mock.patch.object(job.subprocess, "Popen", return_value=process):
            jid = job.start(["exe"], str(folder), str(report_path), self.sid, export_id=rid)
            deadline = time.monotonic() + 5
            while not job.read(jid, 0)["done"] and time.monotonic() < deadline:
                time.sleep(0.01)
        result = job.read(jid, 0)
        self.assertTrue(result["done"])
        self.assertEqual(result["rc"], 0)
        self.assertEqual(result["exportId"], rid)
        self.assertEqual(renditions.result_path(self.sid, rid).read_bytes(), b"converted")


if __name__ == "__main__":
    unittest.main()
