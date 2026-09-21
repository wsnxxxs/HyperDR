import io
import struct
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "apps/panel"))
from hyperdr_panel import raw_profiles, session, schema
from hyperdr_panel.command import build_argv, build_preview_frame_argv


def tiff(fields, magic=42):
    offset = 8 + 2 + 12 * len(fields) + 4
    entries, values = [], b""
    for tag, text in fields.items():
        value = text.encode() + b"\0"
        entries.append(struct.pack("<HHI", tag, 2, len(value)) +
                       (value.ljust(4, b"\0") if len(value) <= 4 else struct.pack("<I", offset + len(values))))
        if len(value) > 4:
            values += value
    return b"II" + struct.pack("<HIH", magic, 8, len(fields)) + b"".join(entries) + b"\0" * 4 + values


class RawProfileTests(unittest.TestCase):
    def test_schema_string_setting_keeps_paths_and_rejects_non_strings(self):
        with patch.dict(schema.SETTINGS, {"raw_profile": {"kind": "string"}}):
            for value in ("", "C:/相机配置/Camera ST.dcp"):
                self.assertEqual(schema.validate_value("raw_profile", value), value)
            for value in (None, False, 12, []):
                with self.assertRaises(ValueError):
                    schema.validate_value("raw_profile", value)

    def test_discovery_upload_identity_and_shared_commands(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(session, "WORK_ROOT", Path(directory)):
            sid = session.create_session()
            source = Path(directory) / "photo.ARW"
            source.write_bytes(tiff({271: "SONY", 272: "ILCE-7RM5"}))
            profiles = Path(directory) / "profiles"
            profiles.mkdir()
            path = profiles / "Sony Adobe Standard.dcp"
            path.write_bytes(tiff({50708: "Sony ILCE-7RM5", 50936: "Adobe Standard"}, 0x4352))
            for filename, camera, name in [
                ("portrait.dcp", "Sony ILCE-7RM5", "Camera PT"),
                ("vivid.dcp", "Sony ILCE-7RM5", "Camera VV"),
                ("other.dcp", "Sony ILCE-7RM4", "Camera PT"),
            ]:
                (profiles / filename).write_bytes(tiff({50708: camera, 50936: name}, 0x4352))
            (profiles / "duplicate.dcp").write_bytes((profiles / "portrait.dcp").read_bytes())
            with patch.object(session, "input_path", return_value=source), patch.object(raw_profiles, "roots", return_value=[profiles]):
                discovered = raw_profiles.discover(sid)
                self.assertEqual([entry["rawProfileName"] for entry in discovered["entries"]],
                                 ["Adobe Standard", "Camera PT", "Camera VV"])
                entry = discovered["entries"][0]
                options = dict(entry, input=str(source), output="output", report="report.json")
                raw_profiles.resolve(options, sid)
                for model in (False, True):
                    options["_model_mode"] = model
                    export = build_argv("HyperDR", options)
                    preview = build_preview_frame_argv("HyperDR", source, "preview.hpf", options, 640)
                    self.assertEqual(export[export.index("--raw-profile") + 1], preview[preview.index("--raw-profile") + 1])
                path.write_bytes(tiff({50708: "Sony ILCE-7RM5", 50936: "Adobe Standard v2"}, 0x4352))
                self.assertNotEqual(entry["rawProfile"], raw_profiles.discover(sid)["entries"][0]["rawProfile"])
                wrong = tiff({50708: "Sony ILCE-7RM4"}, 0x4352)
                with self.assertRaisesRegex(ValueError, "不匹配"):
                    raw_profiles.save(sid, "wrong.dcp", io.BytesIO(wrong), len(wrong))
            with patch.object(session, "input_path", return_value=source.with_suffix(".jpg")):
                self.assertEqual(raw_profiles.discover(sid), {"isRaw": False, "camera": "", "entries": []})
                with self.assertRaisesRegex(ValueError, "仅适用于 RAW"):
                    raw_profiles.resolve(entry.copy(), sid)
            with self.assertRaises(ValueError):
                raw_profiles.resolve({"rawProfile": "C:/private.dcp"}, sid)
            with self.assertRaises(ValueError):
                raw_profiles.resolve(entry.copy(), session.create_session())


if __name__ == "__main__":
    unittest.main()
