"""Admission control and request deduplication for converter subprocesses.

The panel starts a HyperDR process from three places. Only `/api/run` counted
them. `/api/curve` and `/api/preview` each kept a cache, which bounds *finished*
work and says nothing about work in flight: N concurrent misses on one key were
N processes producing one answer.
"""
from __future__ import annotations

import subprocess
import sys
import threading
import time
import unittest
from pathlib import Path
from unittest import mock

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "apps" / "panel"))

from hyperdr_panel import api, curve, thumbnail  # noqa: E402
from hyperdr_panel.concurrency import Budget, Busy, SingleFlight  # noqa: E402


class BudgetTests(unittest.TestCase):
    def test_refuses_beyond_the_limit_instead_of_queueing(self):
        budget = Budget(2)
        held = []
        with budget.hold(), budget.hold():
            with self.assertRaises(Busy) as caught:
                with budget.hold():
                    held.append(1)
        self.assertEqual(caught.exception.status, 503)
        self.assertFalse(held)

    def test_slots_are_returned_after_use(self):
        budget = Budget(1)
        with budget.hold():
            pass
        with budget.hold():
            pass  # A leaked slot would raise here.

    def test_slot_is_returned_when_the_body_raises(self):
        budget = Budget(1)
        with self.assertRaises(RuntimeError):
            with budget.hold():
                raise RuntimeError("boom")
        with budget.hold():
            pass

    def test_timeout_waits_for_a_slot(self):
        budget = Budget(1)
        released = threading.Event()

        def holder():
            with budget.hold():
                released.wait(2)

        worker = threading.Thread(target=holder)
        worker.start()
        time.sleep(0.05)
        released.set()
        with budget.hold(timeout=2.0):
            pass
        worker.join(5)


class SingleFlightTests(unittest.TestCase):
    def test_concurrent_callers_share_one_execution(self):
        flight = SingleFlight()
        started = threading.Event()
        release = threading.Event()
        calls = []
        results = []
        lock = threading.Lock()

        def factory():
            with lock:
                calls.append(1)
            started.set()
            release.wait(5)
            return "value"

        def caller():
            results.append(flight.run("key", factory, timeout=5.0))

        leader = threading.Thread(target=caller)
        leader.start()
        self.assertTrue(started.wait(5))
        followers = [threading.Thread(target=caller) for _ in range(4)]
        for thread in followers:
            thread.start()
        time.sleep(0.05)
        release.set()
        leader.join(5)
        for thread in followers:
            thread.join(5)

        self.assertEqual(len(calls), 1, "one execution for five concurrent callers")
        self.assertEqual(results, ["value"] * 5)

    def test_different_keys_do_not_share(self):
        flight = SingleFlight()
        self.assertEqual(flight.run("a", lambda: 1), 1)
        self.assertEqual(flight.run("b", lambda: 2), 2)

    def test_the_leaders_failure_reaches_every_follower(self):
        flight = SingleFlight()
        started = threading.Event()
        release = threading.Event()
        errors = []

        def factory():
            started.set()
            release.wait(5)
            raise ValueError("no curve for you")

        def caller():
            try:
                flight.run("key", factory, timeout=5.0)
            except ValueError as exc:
                errors.append(str(exc))

        leader = threading.Thread(target=caller)
        leader.start()
        self.assertTrue(started.wait(5))
        follower = threading.Thread(target=caller)
        follower.start()
        time.sleep(0.05)
        release.set()
        leader.join(5)
        follower.join(5)
        self.assertEqual(errors, ["no curve for you"] * 2)

    def test_the_key_is_released_for_the_next_caller(self):
        flight = SingleFlight()
        with self.assertRaises(ValueError):
            flight.run("key", lambda: (_ for _ in ()).throw(ValueError("first")))
        self.assertEqual(flight.in_flight(), 0)
        self.assertEqual(flight.run("key", lambda: "second"), "second")

    def test_a_follower_gives_up_rather_than_blocking_forever(self):
        flight = SingleFlight()
        started = threading.Event()
        release = threading.Event()

        def factory():
            started.set()
            release.wait(5)
            return 1

        leader = threading.Thread(target=lambda: flight.run("key", factory, timeout=5.0))
        leader.start()
        self.assertTrue(started.wait(5))
        with self.assertRaises(Busy):
            flight.run("key", factory, timeout=0.05)
        release.set()
        leader.join(5)


class CurveSingleFlightTests(unittest.TestCase):
    def setUp(self):
        curve._CACHE.clear()

    def tearDown(self):
        curve._CACHE.clear()

    def test_identical_concurrent_requests_run_the_converter_once(self):
        release = threading.Event()
        runs = []
        lock = threading.Lock()

        class Completed:
            returncode = 0
            stdout = b'{"schema": 1}'
            stderr = b""

        def fake_run(_argv, **_kwargs):
            with lock:
                runs.append(1)
            release.wait(5)
            return Completed()

        results = []
        with mock.patch.object(curve.subprocess, "run", fake_run):
            def caller():
                results.append(curve.look_curve("HyperDR", {}, 33))

            threads = [threading.Thread(target=caller) for _ in range(4)]
            for thread in threads:
                thread.start()
            time.sleep(0.1)
            release.set()
            for thread in threads:
                thread.join(10)

        self.assertEqual(len(runs), 1, "four concurrent curve requests, one process")
        self.assertEqual(results, [{"schema": 1}] * 4)

    def test_a_timeout_becomes_a_reportable_error_not_a_traceback(self):
        def fake_run(argv, **kwargs):
            raise subprocess.TimeoutExpired(argv, 30)

        with mock.patch.object(api, "detect_exe", lambda: "HyperDR"), \
                mock.patch.object(curve.subprocess, "run", fake_run):
            response = api.curve(api.Context(output_selections={}),
                                 {"options": {}, "samples": 33})
        self.assertEqual(response.status, 400)
        self.assertIn("超时", response.payload["error"])

    def test_a_full_budget_is_reported_as_busy(self):
        replacement = Budget(1, "busy")
        with mock.patch.object(api, "detect_exe", lambda: "HyperDR"), \
                mock.patch.object(curve, "_BUDGET", replacement):
            with replacement.hold():
                response = api.curve(api.Context(output_selections={}),
                                     {"options": {}, "samples": 41})
        self.assertEqual(response.status, 503)
        self.assertIn("busy", response.payload["error"])


class ThumbnailSingleFlightTests(unittest.TestCase):
    def test_a_thumbnail_timeout_is_converted_to_a_value_error(self):
        # TimeoutExpired is a SubprocessError, which no endpoint catches: it
        # escaped as a traceback and the browser saw the connection drop.
        def fake_run(argv, **kwargs):
            raise subprocess.TimeoutExpired(argv, 180)

        with mock.patch.object(thumbnail, "detect_exe", lambda: "HyperDR"), \
                mock.patch.object(thumbnail.subprocess, "run", fake_run):
            with self.assertRaises(ValueError):
                thumbnail._converter_thumbnail(Path("nonexistent.jpg"))


if __name__ == "__main__":
    unittest.main()
