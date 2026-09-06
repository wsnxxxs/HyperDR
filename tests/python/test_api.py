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

from hyperdr_panel import api, job, session  # noqa: E402

JPEG = b"\xff\xd8\xff" + b"x" * 64


class ApiTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.previous_root = session.WORK_ROOT
        session.WORK_ROOT = Path(self.temporary.name).resolve()
        self.context = api.Context()

    def tearDown(self):
        session._EXTERNAL_INPUTS.clear()
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
        self.assertFalse(response.payload["transportSecure"])
        self.assertNotIn("exe", response.payload)
        self.assertNotIn("path", response.payload)

    def test_desktop_native_path_is_registered_without_copying(self):
        self.context.native_path_input = True
        session_id = session.create_session()
        with tempfile.TemporaryDirectory() as source_root:
            source = Path(source_root) / "camera.jpg"
            source.write_bytes(JPEG)
            response = api.open_native_path(self.context, {
                "sessionId": session_id,
                "path": str(source),
            })
            self.assertEqual(response.status, 201)
            self.assertTrue(response.payload["direct"])
            self.assertEqual(session.input_path(session_id), source.resolve())
            self.assertEqual(list((session.session_dir(session_id, "input")).iterdir()), [])

    def test_native_path_input_is_not_available_to_browser_servers(self):
        session_id = session.create_session()
        response = api.open_native_path(self.context, {
            "sessionId": session_id,
            "path": "C:\\Users\\photo.jpg",
        })
        self.assertEqual(response.status, 404)

    # --- run -------------------------------------------------------------- #

    def test_command_preview_never_starts_a_job(self):
        with mock.patch.object(job, "start") as start:
            response = api.command_preview(self.context, {"options": {"contrast": 1.2}})
        start.assert_not_called()
        self.assertIn("--contrast", response.payload["argv"])
        self.assertEqual(response.payload["argv"][0], "HyperDR")
        self.assertIn("--contrast", response.payload["command"])

    def test_model_command_preview_uses_native_model_and_post_flags(self):
        response = api.command_preview(self.context, {"options": {
            "useModel": True,
            "modelStrength": 1.0,
            "hdrStrength": 0.4,
            "aiBrightness": 0.2,
            "aiContrast": 1.15,
            "aiShadows": -0.25,
            "aiHighlights": 0.35,
            "aiHdrRange": 2.2,
            "aiExpansionStart": 0.4,
        }})
        argv = response.payload["argv"]
        self.assertEqual(argv[argv.index("--gain-strength") + 1], "1")
        self.assertEqual(argv[argv.index("--ai-model") + 1], "embedded")
        for flag, value in {
                "--ai-brightness": "0.2", "--ai-contrast": "1.15",
                "--ai-shadows": "-0.25", "--ai-highlights": "0.35",
                "--ai-hdr-range": "2.2", "--ai-expansion-start": "0.4",
        }.items():
            self.assertEqual(argv[argv.index(flag) + 1], value)
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
                mock.patch.object(job, "start", return_value="job-1"):
            response = api.run(self.context, {
                "sessionId": session_id,
                "options": {"useModel": False},
            })
        self.assertEqual(response.status, 200)

    def test_run_refuses_model_mode_when_the_model_is_disabled(self):
        session_id = self._session_with_image()
        with mock.patch.object(api, "detect_exe", return_value="HyperDR"), \
                mock.patch.object(api.model, "status", return_value={
                    "enabled": False, "ready": False, "reason": "disabled",
                }), \
                mock.patch.object(job, "start") as start:
            response = api.run(self.context, {
                "sessionId": session_id,
                "options": {"useModel": True},
            })
        self.assertEqual(response.status, 400)
        start.assert_not_called()

    def test_run_uses_native_model_without_preparation_commands(self):
        session_id = self._session_with_image()
        with mock.patch.object(api, "detect_exe", return_value="HyperDR"), \
                mock.patch.object(api.model, "status", return_value={
                    "enabled": True, "ready": True,
                }), \
                mock.patch.object(job, "start", return_value="job-1") as start:
            response = api.run(self.context, {
                "sessionId": session_id,
                "options": {"useModel": True, "modelStrength": 0.65},
            })
        self.assertEqual(response.status, 200)
        self.assertNotIn("pre_commands", start.call_args.kwargs)
        argv = start.call_args.args[0]
        self.assertEqual(argv[argv.index("--ai-model") + 1], "embedded")
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
        report = {"width": 3, "height": 2, "max_stops": 3.0}
        with mock.patch.object(api, "detect_exe", return_value="HyperDR"), \
                mock.patch.object(api.model, "status", return_value={
                    "enabled": True, "ready": True,
                }), \
                mock.patch.object(api.model, "native_model_gain", return_value=(gain, report)):
            response = api.model_preview(self.context, {
                "sessionId": session_id,
                "highlightRecovery": "blend",
            })
        self.assertEqual(response.status, 200)
        self.assertEqual(response.body, gain)
        self.assertEqual(response.headers["X-Gain-Width"], "3")
        self.assertEqual(response.headers["X-Gain-Height"], "2")
        self.assertEqual(response.headers["X-Gain-Max-Stops"], "3.0")

    def test_preview_distinguishes_expired_session_from_render_failure(self):
        expired = api.preview(self.context, {
            "id": ["0" * 32], "edge": ["512"],
        })
        self.assertEqual(expired.status, 404)

        session_id = self._session_with_image()
        with mock.patch.object(api, "preview_for",
                               side_effect=ValueError("decode failed")):
            failed = api.preview(self.context, {
                "id": [session_id], "edge": ["512"],
            })
        self.assertEqual(failed.status, 422)

    def test_preview_cancellation_is_not_reported_as_a_decode_failure(self):
        session_id = self._session_with_image()
        with mock.patch.object(api, "preview_for",
                               side_effect=api.PreviewCancelled("superseded")):
            cancelled = api.preview(self.context, {
                "id": [session_id], "edge": ["512"],
            })
        self.assertEqual(cancelled.status, 499)

    def test_preview_reports_native_model_unavailability_as_conflict(self):
        session_id = self._session_with_image()
        with mock.patch.object(api.model, "status", return_value={
                "enabled": False, "ready": False, "reason": "disabled",
        }):
            response = api.preview(self.context, {
                "id": [session_id], "edge": ["512"],
                "options": ['{"useModel":true}'],
            })
        self.assertEqual(response.status, 409)

    def test_a_busy_converter_is_reported_as_too_many_requests(self):
        session_id = self._session_with_image()
        with mock.patch.object(api, "detect_exe", return_value="HyperDR"), \
                mock.patch.object(job, "start", side_effect=job.Busy("已有转换正在进行。")):
            response = api.run(self.context, {"sessionId": session_id})
        self.assertEqual(response.status, 429)

    def test_run_preserves_the_previous_encodings_output(self):
        """A retry must leave the last good result available for download."""
        session_id = self._session_with_image()
        stale = session.session_dir(session_id, "output") / "photo.heic"
        stale.write_bytes(b"old")
        with mock.patch.object(api, "detect_exe", return_value="HyperDR"), \
                mock.patch.object(job, "start", return_value="job-1"):
            api.run(self.context, {"sessionId": session_id})
        self.assertTrue(stale.exists())

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

    # --- paths from the browser ------------------------------------------- #

    def test_unknown_session_ids_are_rejected_everywhere(self):
        for endpoint in (api.preview, api.result):
            response = endpoint(self.context, {"id": ["../../etc"]})
            self.assertEqual(response.status, 404, endpoint.__name__)

    # --- preview parameters ----------------------------------------------- #

    def test_preview_validates_the_requested_edge(self):
        # Rejected before the session id is resolved, so a nonsense edge reads
        # as a bad request rather than an expired upload.
        for edge in ("319", str(api.MAX_EDGE + 1), "not-a-number"):
            response = api.preview(self.context, {"id": ["x"], "edge": [edge]})
            self.assertEqual(response.status, 400, edge)

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
