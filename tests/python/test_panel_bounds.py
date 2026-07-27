"""Bounds and lifecycle rules the panel had no expression for.

Each case here corresponds to something that was unbounded, silently reused, or
raised out of a request handler as a traceback.
"""
from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "apps" / "panel"))

from hyperdr_panel import job  # noqa: E402
from hyperdr_panel.handler import MAX_BODY_BYTES, Handler  # noqa: E402


class JobLogBoundsTests(unittest.TestCase):
    """A converter stuck in a warning loop must not grow the log without limit."""

    def setUp(self):
        self.record = {
            "id": "test-job", "log": "", "dropped": 0, "truncated": False,
            "done": False, "rc": None, "report": None, "report_path": "",
            "proc": None, "cancelled": False, "timed_out": False,
            "session_id": "", "finished_at": None,
        }
        self.previous_max = job.MAX_LOG_CHARS
        job.MAX_LOG_CHARS = 100
        with job._LOCK:
            self.previous_job = job._JOB
            job._JOB = self.record

    def tearDown(self):
        job.MAX_LOG_CHARS = self.previous_max
        with job._LOCK:
            job._JOB = self.previous_job

    def test_the_retained_log_stays_within_its_budget(self):
        for index in range(50):
            job._append_locked(self.record, "line %02d\n" % index)
        self.assertLessEqual(len(self.record["log"]), job.MAX_LOG_CHARS)
        self.assertTrue(self.record["truncated"])
        self.assertGreater(self.record["dropped"], 0)

    def test_offsets_stay_absolute_across_a_drop(self):
        """A client's offset counts bytes ever written, not bytes retained."""
        for index in range(50):
            job._append_locked(self.record, "line %02d\n" % index)
        result = job.read("test-job", 0)
        self.assertEqual(result["offset"], self.record["dropped"] + len(self.record["log"]))
        self.assertEqual(result["logStart"], self.record["dropped"])

    def test_a_client_polling_from_a_discarded_offset_is_told_so(self):
        for index in range(50):
            job._append_locked(self.record, "line %02d\n" % index)
        result = job.read("test-job", 0)
        self.assertTrue(result["truncated"])
        # Moved forward to where the log now begins rather than handed a slice
        # measured from an origin that no longer exists.
        self.assertEqual(result["text"], self.record["log"])

    def test_a_short_log_is_never_marked_truncated(self):
        job._append_locked(self.record, "brief\n")
        result = job.read("test-job", 0)
        self.assertFalse(result["truncated"])
        self.assertEqual(result["text"], "brief\n")
        self.assertEqual(result["logStart"], 0)

    def test_polling_past_the_end_returns_nothing_rather_than_failing(self):
        job._append_locked(self.record, "brief\n")
        self.assertEqual(job.read("test-job", 9999)["text"], "")

    def test_an_empty_append_changes_nothing(self):
        job._append_locked(self.record, "")
        self.assertEqual(self.record["log"], "")
        self.assertFalse(self.record["truncated"])


class JsonBodyTests(unittest.TestCase):
    """`json.loads` returns whatever the document is; routes assume a dict."""

    @staticmethod
    def _reader(body: bytes) -> Handler:
        class FakeFile:
            def __init__(self, data):
                self._data = data

            def read(self, length):
                return self._data[:length]

        reader = Handler.__new__(Handler)
        reader.headers = {"Content-Length": str(len(body))}
        reader.rfile = FakeFile(body)
        return reader

    def test_a_valid_non_object_document_is_a_client_error(self):
        for body in (b"[]", b'"text"', b"7", b"null", b"true"):
            with self.assertRaises(ValueError, msg=body):
                self._reader(body)._read_json()

    def test_an_object_is_accepted(self):
        body = json.dumps({"sessionId": "x"}).encode("utf-8")
        self.assertEqual(self._reader(body)._read_json(), {"sessionId": "x"})

    def test_an_oversized_body_is_refused_before_it_is_read(self):
        reader = self._reader(b"{}")
        reader.headers = {"Content-Length": str(MAX_BODY_BYTES + 1)}
        with self.assertRaises(ValueError):
            reader._read_json()


if __name__ == "__main__":
    unittest.main()
