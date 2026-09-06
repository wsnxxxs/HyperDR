import io
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "apps/panel"))
from hyperdr_panel import color_lut, session
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


if __name__ == "__main__":
    unittest.main()
