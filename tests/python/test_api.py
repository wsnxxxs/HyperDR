"""The HTTP API's behaviour, without a socket.

Every endpoint used to be a method on the request handler, so none of this was
reachable from a test. These cases pin the parts that are easy to get wrong and
expensive to get wrong: refusing paths the browser supplies, refusing an export
outside the chosen folder, and never leaking the executable's location.
"""
from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "apps" / "panel"))

from hyperdr_panel import api, curve, job, session  # noqa: E402

JPEG = b"\xff\xd8\xff" + b"x" * 64


class ApiTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.previous_root = session.WORK_ROOT
        session.WORK_ROOT = Path(self.temporary.name).resolve()
        self.context = api.Context(output_selections={})

    def tearDown(self):
        session.WORK_ROOT = self.previous_root
        self.temporary.cleanup()

    def _session_with_image(self) -> str:
        session_id = session.create_session()
        (session.session_dir(session_id, "input") / "photo.jpg").write_bytes(JPEG)
        return session_id

    # --- state ------------------------------------------------------------ #

    def test_state_reports_readiness_without_revealing_the_path(self):
        response = api.state(self.context, {})
        self.assertEqual(response.status, 200)
        self.assertIn("ready", response.payload)
        self.assertIn("previewMaxEdge", response.payload)
        self.assertTrue(response.payload["hdrPreviewRequiresSecureContext"])
        self.assertNotIn("exe", response.payload)
        self.assertNotIn("path", response.payload)

    # --- run -------------------------------------------------------------- #

    def test_command_preview_never_starts_a_job(self):
        with mock.patch.object(job, "start") as start:
            response = api.command_preview(self.context, {"options": {"contrast": 1.2}})
        start.assert_not_called()
        self.assertIn("--contrast", response.payload["argv"])
        self.assertEqual(response.payload["argv"][0], "HyperDR")
        self.assertIn("--contrast", response.payload["command"])

    def test_model_command_preview_uses_model_strength_and_external_gain(self):
        response = api.command_preview(self.context, {"options": {
            "useModel": True,
            "modelStrength": 1.0,
            "hdrStrength": 0.4,
        }})
        argv = response.payload["argv"]
        self.assertEqual(argv[argv.index("--gain-strength") + 1], "1")
        self.assertIn("--external-gain", argv)
        self.assertIn("--external-gain-report", argv)
        for flag in ("--look", "--contrast", "--vibrance", "--pop",
                     "--headroom-max", "--exposure-bias", "--expansion-start",
                     "--area-coverage", "--exposure", "--headroom"):
            self.assertNotIn(flag, argv, flag)

    def test_run_reports_a_missing_executable_rather_than_failing_later(self):
        session_id = self._session_with_image()
        with mock.patch.object(api, "detect_exe", return_value=""):
            response = api.run(self.context, {"sessionId": session_id})
        self.assertEqual(response.status, 400)
        self.assertIn("error", response.payload)

    def test_run_reports_an_empty_session(self):
        session_id = session.create_session()
        with mock.patch.object(api, "detect_exe", return_value="HyperDR"):
            response = api.run(self.context, {"sessionId": session_id})
        self.assertEqual(response.status, 400)

    def test_run_hides_the_executable_path_from_the_browser(self):
        session_id = self._session_with_image()
        with mock.patch.object(api, "detect_exe", return_value="/opt/secret/HyperDR"), \
                mock.patch.object(job, "start", return_value="job-1"):
            response = api.run(self.context, {"sessionId": session_id})
        self.assertEqual(response.payload["jobId"], "job-1")
        self.assertEqual(response.payload["argv"][0], "HyperDR")
        self.assertNotIn("/opt/secret", " ".join(response.payload["argv"]))
        self.assertNotIn("/opt/secret", response.payload["command"])

    def test_run_keeps_the_mathematical_path_until_model_is_requested(self):
        session_id = self._session_with_image()
        with mock.patch.object(api, "detect_exe", return_value="HyperDR"), \
                mock.patch.object(api.model, "load_config") as load_model, \
                mock.patch.object(job, "start", return_value="job-1"):
            response = api.run(self.context, {
                "sessionId": session_id,
                "options": {"useModel": False},
            })
        self.assertEqual(response.status, 200)
        load_model.assert_not_called()

    def test_run_uses_model_only_after_explicit_optimization(self):
        session_id = self._session_with_image()
        output = session.session_dir(session_id, "output")
        gain = output / ".model" / "model-gain.f32"
        report = output / ".model" / "model-gain.json"
        with mock.patch.object(api, "detect_exe", return_value="HyperDR"), \
                mock.patch.object(api.model, "load_config", return_value=object()), \
                mock.patch.object(
                    api.model, "build_commands",
                    return_value=([["model"]], gain, report),
                ) as build_model, \
                mock.patch.object(job, "start", return_value="job-1") as start:
            response = api.run(self.context, {
                "sessionId": session_id,
                "options": {"useModel": True, "modelStrength": 0.65},
            })
        self.assertEqual(response.status, 200)
        build_model.assert_called_once()
        self.assertEqual(start.call_args.kwargs["pre_commands"], [["model"]])
        argv = start.call_args.args[0]
        self.assertEqual(argv[argv.index("--gain-strength") + 1], "0.65")

    def test_model_strength_is_bounded(self):
        session_id = self._session_with_image()
        with mock.patch.object(api, "detect_exe", return_value="HyperDR"):
            response = api.run(self.context, {
                "sessionId": session_id,
                "options": {"useModel": True, "modelStrength": 1.5},
            })
        self.assertEqual(response.status, 400)

    def test_model_preview_returns_the_float_grid_contract(self):
        session_id = self._session_with_image()
        gain = b"\x00\x00\x00\x00" * 6
        report = {
            "gain_grid_size": [3, 2],
            "metadata_gain_max_stops": 3.0,
        }
        with mock.patch.object(api, "detect_exe", return_value="HyperDR"), \
                mock.patch.object(api.model, "load_config", return_value=object()), \
                mock.patch.object(api.model, "infer_preview", return_value=(gain, report)):
            response = api.model_preview(self.context, {
                "sessionId": session_id,
                "highlightRecovery": "blend",
            })
        self.assertEqual(response.status, 200)
        self.assertEqual(response.body, gain)
        self.assertEqual(response.headers["X-Gain-Width"], "3")
        self.assertEqual(response.headers["X-Gain-Height"], "2")
        self.assertEqual(response.headers["X-Gain-Max-Stops"], "3.0")

    def test_a_busy_converter_is_reported_as_too_many_requests(self):
        session_id = self._session_with_image()
        with mock.patch.object(api, "detect_exe", return_value="HyperDR"), \
                mock.patch.object(job, "start", side_effect=job.Busy("已有转换正在进行。")):
            response = api.run(self.context, {"sessionId": session_id})
        self.assertEqual(response.status, 429)

    def test_run_clears_the_previous_encodings_output(self):
        """Otherwise `result_path` could hand back the last run's file."""
        session_id = self._session_with_image()
        stale = session.session_dir(session_id, "output") / "photo.heic"
        stale.write_bytes(b"old")
        with mock.patch.object(api, "detect_exe", return_value="HyperDR"), \
                mock.patch.object(job, "start", return_value="job-1"):
            api.run(self.context, {"sessionId": session_id})
        self.assertFalse(stale.exists())

    # --- result ----------------------------------------------------------- #

    def test_each_container_is_served_as_its_own_type(self):
        for name, expected in (("photo.avif", "image/avif"),
                               ("photo.heic", "image/heic"),
                               ("photo.jpg", "image/jpeg")):
            session_id = session.create_session()
            (session.session_dir(session_id, "output") / name).write_bytes(b"result")
            response = api.result(self.context, {"id": [session_id]})
            self.assertEqual(response.content_type, expected, name)
            self.assertFalse(response.download)

    def test_a_download_is_requested_explicitly(self):
        """This is how a phone saves the file; the folder dialog cannot reach it."""
        session_id = session.create_session()
        (session.session_dir(session_id, "output") / "photo.heic").write_bytes(b"r")
        response = api.result(self.context, {"id": [session_id], "download": ["1"]})
        self.assertTrue(response.download)

    def test_a_session_with_no_result_is_a_not_found(self):
        session_id = session.create_session()
        self.assertEqual(api.result(self.context, {"id": [session_id]}).status, 404)

    # --- export ----------------------------------------------------------- #

    def test_export_requires_a_selection_the_server_issued(self):
        session_id = session.create_session()
        response = api.export(self.context, {"sessionId": session_id, "selectionId": "made-up"})
        self.assertEqual(response.status, 400)
        # A path from the browser is never accepted, only an id from select_output.
        with tempfile.TemporaryDirectory() as elsewhere:
            response = api.export(self.context, {
                "sessionId": session_id, "destination": elsewhere,
            })
            self.assertEqual(response.status, 400)

    def test_export_copies_the_result_into_the_chosen_folder(self):
        session_id = session.create_session()
        (session.session_dir(session_id, "output") / "photo.heic").write_bytes(b"result")
        with tempfile.TemporaryDirectory() as chosen:
            self.context.output_selections["ok"] = Path(chosen).resolve()
            response = api.export(self.context, {"sessionId": session_id, "selectionId": "ok"})
            self.assertEqual(response.status, 200)
            self.assertEqual((Path(chosen) / "photo.heic").read_bytes(), b"result")

    # --- paths from the browser ------------------------------------------- #

    def test_unknown_session_ids_are_rejected_everywhere(self):
        for endpoint in (api.preview, api.result):
            response = endpoint(self.context, {"id": ["../../etc"]})
            self.assertEqual(response.status, 404, endpoint.__name__)

    # --- curve ------------------------------------------------------------ #

    def test_curve_validates_the_sample_count(self):
        with mock.patch.object(api, "detect_exe", return_value="HyperDR"):
            for samples in (1, 5000):
                self.assertEqual(api.curve(self.context, {"samples": samples}).status, 400, samples)

    def test_curve_timeout_is_converted_to_a_request_error(self):
        with mock.patch.object(api, "detect_exe", return_value="HyperDR"), \
                mock.patch.object(curve.subprocess, "run",
                                  side_effect=subprocess.TimeoutExpired(["HyperDR"], 30)):
            self.assertEqual(api.curve(self.context, {}).status, 400)

    # --- log -------------------------------------------------------------- #

    def test_job_log_rejects_a_bad_offset(self):
        self.assertEqual(api.job_log(self.context, {"id": ["x"], "offset": ["abc"]}).status, 400)
        self.assertEqual(api.job_log(self.context, {"id": ["unknown"]}).status, 404)

    # --- routing ---------------------------------------------------------- #

    def test_routes_are_registered_once_each(self):
        self.assertEqual(len(api.GET_ROUTES), len(set(api.GET_ROUTES)))
        self.assertEqual(len(api.POST_ROUTES), len(set(api.POST_ROUTES)))
        for path, handler in {**api.GET_ROUTES, **api.POST_ROUTES}.items():
            self.assertTrue(path.startswith("/api/"), path)
            self.assertTrue(callable(handler), path)

    def test_endpoints_answer_a_bad_request_rather_than_raising(self):
        """`handler.py` turns an escape into a 500; none should get that far."""
        for path, endpoint in api.GET_ROUTES.items():
            response = endpoint(self.context, {})
            self.assertGreaterEqual(response.status, 200, path)


if __name__ == "__main__":
    unittest.main()
