import io
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "apps/panel"))
from hyperdr_panel import color_lut, session, lut_library, api
from hyperdr_panel.command import build_argv, build_preview_frame_argv


class ColorLutTests(unittest.TestCase):
    def test_upload_identity_and_shared_preview_export_flags(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(session, "WORK_ROOT", Path(directory)):
            sid = session.create_session()
            data = b'LUT_1D_SIZE 2\n0 0 0\n1 .9 .8\n'
            saved = color_lut.save(sid, "Warm.cube", io.BytesIO(data), len(data))
            options = dict(saved, encoding="sdr-jpeg", lutInput="srgb", lutOutput="srgb", lutStrength=.6,
                           input="photo.HIF", output="output", report="report.json")
            color_lut.resolve(options, sid)
            exported = build_argv("HyperDR", options)
            previewed = build_preview_frame_argv("HyperDR", "photo.HIF", "preview.hpf", options, 640)
            for flag in ["--lut", "--lut-input", "--lut-output", "--lut-strength", "--encoding"]:
                self.assertEqual(exported[exported.index(flag)+1], previewed[previewed.index(flag)+1])
            self.assertEqual(exported[exported.index("--depth")+1], "8")
            other = session.create_session()
            with self.assertRaises(ValueError):
                color_lut.resolve(dict(saved), other)

    def test_calibration_lut_is_not_a_creative_cube(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(session, "WORK_ROOT", Path(directory)):
            sid = session.create_session()
            with self.assertRaisesRegex(ValueError, "RAW"):
                color_lut.save(sid, "calibration.cube", io.BytesIO(b"3 0 .5 1"), 8)

    def test_library_reuses_lut_across_photos_and_keeps_history_after_removal(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(session, "WORK_ROOT", Path(directory)):
            sid = session.create_session()
            data = b'LUT_1D_SIZE 2\n0 0 0\n1 .9 .8\n'
            saved = color_lut.save(sid, "Warm.cube", io.BytesIO(data), len(data))
            lut_library.add(sid, saved)
            context = api.Context()
            api.manage_lut(context, dict(saved, action="update", lutInput="rec709", lutOutput="srgb"))
            # Reimporting the same content keeps its remembered space settings.
            self.assertEqual(lut_library.add(sid, saved)["lutInput"], "rec709")
            self.assertEqual(len(api.list_luts(context, {}).payload["entries"]), 1)
            other = session.create_session()
            applied = api.manage_lut(context, dict(saved, action="apply", sessionId=other)).payload
            self.assertEqual(applied["lutInput"], "rec709")
            color_lut.resolve(applied, other)
            self.assertEqual(Path(applied["_lut_path"]).read_bytes(), data)
            api.manage_lut(context, dict(saved, action="remove"))
            self.assertEqual(lut_library.entries(), [])
            # Removing a reusable look must not break either photo's exports/undo.
            color_lut.resolve(dict(saved), sid)
            color_lut.resolve(dict(saved), other)

    def test_library_survives_session_expiry(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(session, "WORK_ROOT", Path(directory)):
            sid = session.create_session()
            data = b'LUT_1D_SIZE 2\n0 0 0\n1 1 1\n'
            saved = color_lut.save(sid, "Identity.cube", io.BytesIO(data), len(data))
            lut_library.add(sid, saved)
            session.cleanup_expired_sessions(now=10**12)
            self.assertEqual(len(lut_library.entries()), 1)
            other = session.create_session()
            color_lut.resolve(lut_library.apply(other, saved["lutId"]), other)


if __name__ == "__main__":
    unittest.main()
