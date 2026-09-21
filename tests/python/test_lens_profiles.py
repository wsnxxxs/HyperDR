import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "apps/panel"))
from hyperdr_panel import lens_profiles, session
from hyperdr_panel.command import build_argv, build_preview_frame_argv


class LensProfileTests(unittest.TestCase):
    def test_matching_requires_exact_lens_raw_and_compatible_camera(self):
        metadata = {"make": "SONY", "model": "ILCE-7RM5", "lens": "FE 24-70mm F2.8 GM II"}
        fields = {"Make": "Sony", "LensPrettyName": "Sony FE 24-70mm F2.8 GM II", "CameraRawProfile": "True"}
        self.assertTrue(lens_profiles.match_profile(metadata, fields))
        for update in ({"CameraRawProfile": "False"}, {"Make": "Canon"},
                       {"Model": "ILCE-7RM4"}, {"LensPrettyName": "Sony FE 24-70mm F2.8 GM"}):
            self.assertFalse(lens_profiles.match_profile(metadata, dict(fields, **update)))
        self.assertFalse(lens_profiles.match_profile(dict(metadata, lens=""), fields))

    def test_discovery_copies_supported_profile_and_raw_only_resolution(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(session, "WORK_ROOT", Path(directory)):
            sid = session.create_session()
            source = Path(directory) / "photo.ARW"
            source.write_bytes(b"raw")
            profiles = Path(directory) / "profiles"
            profiles.mkdir()
            profile = profiles / "sample.lcp"
            profile.write_text('''<root xmlns:c="http://ns.adobe.com/photoshop/1.0/camera-profile">
              <item c:Make="SONY" c:Lens="FE 50mm F1.8" c:CameraRawProfile="True" c:ProfileName="Adobe 50mm">
                <c:PerspectiveModel c:Version="2" c:FocalLengthX="1.4" c:FocalLengthY="1.4" />
              </item></root>''')
            metadata = {"make": "SONY", "model": "ILCE-7M4", "lens": "FE 50mm F1.8", "focalLength": 50}
            with patch.object(session, "input_path", return_value=source), patch.object(lens_profiles, "roots", return_value=[profiles]), patch.object(lens_profiles, "source_metadata", return_value=metadata):
                result = lens_profiles.discover(sid)
                self.assertTrue(result["available"])
                self.assertEqual(Path(result["profilePath"]).read_bytes(), profile.read_bytes())
                self.assertNotEqual(result["profilePath"], str(profile))
                options = {}
                lens_profiles.resolve(options, sid)
                self.assertEqual(options["_lens_profile_path"], result["profilePath"])
                options.update(input=str(source), output="output", report="report.json")
                for model in (False, True):
                    options["_model_mode"] = model
                    export = build_argv("HyperDR", options)
                    preview = build_preview_frame_argv("HyperDR", source, "preview.hpf", options, 640)
                    self.assertEqual(export[export.index("--raw-lens-profile") + 1],
                                     preview[preview.index("--raw-lens-profile") + 1])
                options["lensCorrection"] = False
                lens_profiles.resolve(options, sid)
                self.assertNotIn("_lens_profile_path", options)
            jpg = source.with_suffix(".jpg")
            jpg.write_bytes(b"jpeg")
            with patch.object(session, "input_path", return_value=jpg):
                self.assertFalse(lens_profiles.discover(sid)["available"])
                options = {"lensCorrection": True}
                lens_profiles.resolve(options, sid)
                self.assertNotIn("_lens_profile_path", options)

    def test_modern_lightroom_profile_can_derive_normalized_focal_length(self):
        with tempfile.TemporaryDirectory() as directory:
            profile = Path(directory) / "modern.lcp"
            profile.write_text('<root xmlns:c="http://ns.adobe.com/photoshop/1.0/camera-profile">'
                               '<item c:FocalLength="24" c:SensorFormatFactor="1">'
                               '<c:PerspectiveModel c:Version="2" c:RadialDistortParam1="-0.1"/>'
                               '</item></root>')
            stat = profile.stat()
            self.assertTrue(lens_profiles._read_profile(str(profile), stat.st_mtime_ns, stat.st_size)["_supported"])

    def test_unsupported_geometry_is_not_selected(self):
        with tempfile.TemporaryDirectory() as directory:
            profile = Path(directory) / "unsupported.lcp"
            for geometry in ('<c:FisheyeModel c:Version="2"/>', '<c:PerspectiveModel c:Version="2"/>'):
                profile.write_text('<root xmlns:c="http://ns.adobe.com/photoshop/1.0/camera-profile">' + geometry + '</root>')
                stat = profile.stat()
                self.assertFalse(lens_profiles._read_profile(str(profile), stat.st_mtime_ns, stat.st_size)["_supported"])


if __name__ == "__main__":
    unittest.main()
