"""The running conversion: admission, cancellation, log offsets, shutdown.

One image at a time means one process at a time, so the interesting property is
no longer "which of several jobs did this poll mean" but "a second start is
refused, and every path still reaches a terminal state".
"""
from __future__ import annotations

import threading
import time
import unittest
from unittest import mock

from apps.panel.hyperdr_panel import job


class FakeProcess:
    """A Popen stand-in whose stream and exit can be driven from the test."""

    def __init__(self, lines=(), returncode=0, block=None):
        self._lines = list(lines)
        self._block = block
        self.returncode = returncode
        self.stdout = self
        self.terminated = False
        self.killed = False
        self._finished = False

    def __iter__(self):
        for line in self._lines:
            yield line
        if self._block is not None:
            self._block.wait(5)

    def wait(self, timeout=None):
        self._finished = True
        return self.returncode

    def poll(self):
        return self.returncode if self._finished or self.terminated else None

    def terminate(self):
        self.terminated = True

    def kill(self):
        self.killed = True


class JobTests(unittest.TestCase):
    def setUp(self):
        self._reset()

    def tearDown(self):
        self._reset()

    @staticmethod
    def _reset():
        with job._LOCK:
            job._JOB = None
            job._ACCEPTING = True

    def _wait_done(self, job_id, timeout=5.0):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            record = job.read(job_id, 0)
            if record and record["done"]:
                return record
            time.sleep(0.01)
        self.fail("job never reached a terminal state")

    # --- admission -------------------------------------------------------- #

    def test_a_second_conversion_is_refused_while_one_runs(self):
        release = threading.Event()
        process = FakeProcess(lines=["working\n"], block=release)
        with mock.patch.object(job.subprocess, "Popen", return_value=process):
            first = job.start(["exe"], ".", "", "session-a")
            # Poll until the pump has actually taken the process, so the refusal
            # below is about admission rather than a race with thread startup.
            deadline = time.monotonic() + 5
            while job.read(first, 0) is None and time.monotonic() < deadline:
                time.sleep(0.01)
            with self.assertRaises(job.Busy):
                job.start(["exe"], ".", "", "session-b")
            release.set()
        self._wait_done(first)

    def test_a_finished_conversion_does_not_block_the_next(self):
        with mock.patch.object(job.subprocess, "Popen", return_value=FakeProcess()):
            first = job.start(["exe"], ".", "", "s")
            self._wait_done(first)
            second = job.start(["exe"], ".", "", "s")
            self._wait_done(second)
        self.assertNotEqual(first, second)

    def test_starting_replaces_the_previous_job_record(self):
        """Only the current job is readable; the old id stops resolving."""
        with mock.patch.object(job.subprocess, "Popen", return_value=FakeProcess()):
            first = job.start(["exe"], ".", "", "s")
            self._wait_done(first)
            second = job.start(["exe"], ".", "", "s")
            self._wait_done(second)
        self.assertIsNone(job.read(first, 0))
        self.assertIsNotNone(job.read(second, 0))

    # --- cancellation ----------------------------------------------------- #

    def test_cancel_before_popen_prevents_the_process_starting(self):
        started = threading.Event()

        def never(*args, **kwargs):
            started.set()
            raise AssertionError("process must not start")

        with job._LOCK:
            job._JOB = {
                "id": "j", "log": "", "dropped": 0, "truncated": False,
                "done": False, "rc": None, "report": None, "report_path": "",
                "proc": None, "cancelled": True, "timed_out": False,
                "session_id": "s", "finished_at": None,
            }
            record = job._JOB
        with mock.patch.object(job.subprocess, "Popen", never):
            job._pump(record, ["exe"], ".")
        self.assertFalse(started.is_set())
        self.assertTrue(record["done"])
        self.assertIn("取消", record["log"])

    def test_cancel_reports_false_for_a_job_that_is_not_current(self):
        self.assertFalse(job.cancel("nonexistent"))

    def test_stop_escalates_to_kill_after_the_grace_period(self):
        process = FakeProcess()
        process.wait = mock.Mock(side_effect=[job.subprocess.TimeoutExpired("x", 1), 0])
        process.poll = mock.Mock(return_value=None)
        job._stop(process)
        self.assertTrue(process.terminated)
        self.assertTrue(process.killed)

    # --- failure ---------------------------------------------------------- #

    def test_a_stream_failure_still_reaches_a_terminal_state(self):
        """A crash inside the pump must not leave the panel polling forever."""
        with mock.patch.object(job.subprocess, "Popen", side_effect=OSError("boom")):
            job_id = job.start(["exe"], ".", "", "s")
            record = self._wait_done(job_id)
        self.assertEqual(record["rc"], -1)
        self.assertIn("boom", record["text"])

    def test_a_nonzero_exit_is_reported(self):
        with mock.patch.object(job.subprocess, "Popen",
                               return_value=FakeProcess(returncode=3)):
            record = self._wait_done(job.start(["exe"], ".", "", "s"))
        self.assertEqual(record["rc"], 3)

    # --- log -------------------------------------------------------------- #

    def test_the_log_is_served_incrementally_by_offset(self):
        with mock.patch.object(job.subprocess, "Popen",
                               return_value=FakeProcess(lines=["one\n", "two\n"])):
            job_id = job.start(["exe"], ".", "", "s")
            record = self._wait_done(job_id)
        self.assertEqual(record["text"], "one\ntwo\n")
        self.assertEqual(job.read(job_id, record["offset"])["text"], "")
        self.assertEqual(job.read(job_id, 4)["text"], "two\n")

    def test_the_active_session_is_reported_only_while_running(self):
        release = threading.Event()
        with mock.patch.object(job.subprocess, "Popen",
                               return_value=FakeProcess(block=release)):
            job_id = job.start(["exe"], ".", "", "session-x")
            deadline = time.monotonic() + 5
            while not job.is_running() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertEqual(job.active_session_id(), "session-x")
            release.set()
            self._wait_done(job_id)
        self.assertEqual(job.active_session_id(), "")

    # --- shutdown --------------------------------------------------------- #

    def test_shutdown_stops_admission_and_the_active_process(self):
        release = threading.Event()
        process = FakeProcess(block=release)
        with mock.patch.object(job.subprocess, "Popen", return_value=process):
            job_id = job.start(["exe"], ".", "", "s")
            deadline = time.monotonic() + 5
            while not job.is_running() and time.monotonic() < deadline:
                time.sleep(0.01)
            release.set()
            job.shutdown(wait_seconds=2.0)
        self.assertTrue(process.terminated)
        with self.assertRaises(job.Busy):
            job.start(["exe"], ".", "", "s")
        self._wait_done(job_id)


if __name__ == "__main__":
    unittest.main()
