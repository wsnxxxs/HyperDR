"""The panel's side of the settings contract.

Two things used to drift silently and are pinned here: the command line the
panel displayed versus the one it ran, and the settings vocabulary the browser
sends versus the one the converter accepts.
"""
from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "apps" / "panel"))

from hyperdr_panel import schema  # noqa: E402
from hyperdr_panel import model  # noqa: E402
from hyperdr_panel.executable import detect_exe  # noqa: E402
from hyperdr_panel.command import (  # noqa: E402
    build_argv,
    build_curve_argv,
    options_to_settings,
)


def flags(argv: list[str]) -> dict[str, str]:
    """Map each --flag to its value; value-less flags map to the empty string."""
    found: dict[str, str] = {}
    index = 0
    while index < len(argv):
        item = argv[index]
        if item.startswith("--"):
            following = argv[index + 1] if index + 1 < len(argv) else ""
            if following.startswith("--"):
                found[item] = ""
                index += 1
            else:
                found[item] = following
                index += 2
        else:
            index += 1
    return found


BASE = {"input": "in", "output": "out", "report": "out/report.json"}


class BuildArgvTest(unittest.TestCase):
    def test_defaults_are_complete_and_ordered(self):
        argv = build_argv("HyperDR", dict(BASE))
        self.assertEqual(argv[:5], ["HyperDR", "convert", "in", "--output", "out"])
        self.assertEqual(argv[-2:], ["--report", "out/report.json"])
        found = flags(argv)
        for flag in ("--encoding", "--look", "--contrast", "--vibrance",
                     "--gain-strength", "--headroom-max", "--pop", "--exposure-bias",
                     "--expansion-start", "--area-coverage", "--exposure",
                     "--headroom", "--highlight-recovery", "--quality", "--depth"):
            self.assertIn(flag, found, flag)

    def test_defaults_match_panel_controls(self):
        found = flags(build_argv("HyperDR", dict(BASE)))
        self.assertEqual(found["--gain-strength"], "0.4")
        self.assertEqual(found["--pop"], "0.4")

    def test_panel_options_are_not_silently_coerced(self):
        for options in ({"quality": 90.9}, {"contrast": "1.2"},
                        {"highlightRecovery": "nope"}):
            with self.assertRaises(ValueError, msg=str(options)):
                options_to_settings(options)

    def test_the_renderer_is_fixed_and_a_stale_client_cannot_change_it(self):
        """The renderer decides what /api/curve draws, so a client cannot pick it."""
        self.assertEqual(flags(build_argv("HyperDR", dict(BASE)))["--look"],
                         "photographic")
        # `neutral` was the second look until it was removed; a stale client
        # still asking for it must be pinned, not passed through to the CLI,
        # which would now reject the name outright.
        found = flags(build_argv("HyperDR", dict(BASE, look="neutral")))
        self.assertEqual(found["--look"], "photographic")

    def test_batch_flags_are_never_emitted(self):
        """One image at a time: these only meant something for a folder pass."""
        found = flags(build_argv("HyperDR", dict(BASE)))
        for flag in ("--recursive", "--threads", "--skip-existing", "--overwrite",
                     "--preview-max-edge", "--decode-cache"):
            self.assertNotIn(flag, found, flag)

    def test_verification_is_never_disabled(self):
        """It is what stops a broken gain map reaching the disk, not a preference."""
        self.assertNotIn("--no-verify", flags(build_argv("HyperDR", dict(BASE))))
        # Even if a stale client still sends the old control.
        self.assertNotIn(
            "--no-verify", flags(build_argv("HyperDR", dict(BASE, verifyOutput=False))))

    def test_the_full_quality_setting_always_reaches_the_encoder(self):
        self.assertEqual(flags(build_argv("HyperDR", dict(BASE)))["--quality"], "90")
        self.assertEqual(
            flags(build_argv("HyperDR", dict(BASE, quality=72)))["--quality"], "72")

    def test_bt2100_encodings_are_ten_bit(self):
        for encoding in ("pq", "hlg", "avif-pq", "avif-hlg"):
            found = flags(build_argv("HyperDR", dict(BASE, encoding=encoding)))
            self.assertEqual(found["--depth"], "10", encoding)
        for encoding in ("adaptive", "ultrahdr"):
            found = flags(build_argv("HyperDR", dict(BASE, encoding=encoding)))
            self.assertEqual(found["--depth"], "8", encoding)

    def test_hlg_encodings_default_to_supported_headroom(self):
        for encoding in ("hlg", "avif-hlg"):
            found = flags(build_argv("HyperDR", dict(BASE, encoding=encoding)))
            self.assertEqual(found["--headroom"], "2.3", encoding)
            self.assertEqual(found["--headroom-max"], "2.3", encoding)
            with self.assertRaises(ValueError):
                build_argv("HyperDR", dict(BASE, encoding=encoding, hdrRange=2.5))

    def test_one_knob_drives_both_strength_settings(self):
        found = flags(build_argv("HyperDR", dict(BASE, hdrStrength=0.6, hdrRange=3.0)))
        self.assertEqual(found["--gain-strength"], found["--pop"])
        self.assertEqual(found["--headroom"], found["--headroom-max"])

    def test_curve_argv_matches_the_render_settings(self):
        options = dict(BASE, contrast=1.2, hdrRange=3.0, expansionStart=0.55)
        found = flags(build_curve_argv("HyperDR", options, 129))
        self.assertEqual(found["--contrast"], "1.2")
        self.assertEqual(found["--headroom"], "3")
        self.assertEqual(found["--expansion-start"], "0.55")
        self.assertEqual(found["--samples"], "129")

    def test_external_gain_pair_reaches_converter(self):
        found = flags(build_argv(
            "HyperDR", dict(BASE, external_gain="out/gain.f32",
                             external_gain_report="out/gain.json")))
        self.assertEqual(found["--external-gain"], "out/gain.f32")
        self.assertEqual(found["--external-gain-report"], "out/gain.json")
        self.assertEqual(found["--gain-strength"], "0.4")
        for flag in ("--look", "--contrast", "--vibrance", "--pop",
                     "--headroom-max", "--exposure-bias", "--expansion-start",
                     "--area-coverage", "--exposure", "--headroom"):
            self.assertNotIn(flag, found, flag)

    def test_external_gain_requires_both_files(self):
        with self.assertRaises(ValueError):
            build_argv("HyperDR", dict(BASE, external_gain="out/gain.f32"))


class ModelIntegrationTest(unittest.TestCase):
    def test_raster_input_uses_native_photographic_base(self):
        config = model.ModelConfig(
            root=Path("model"), python="python", script=Path("model/infer_gain.py"),
            checkpoint=Path("model/best.pt"), dataset_root=Path("dataset"),
            device="cpu", long_side=1024,
        )
        with tempfile.TemporaryDirectory() as directory:
            commands, gain, report = model.build_commands(
                config, Path("photo.jpg"), Path(directory) / ".model", "HyperDR")
        self.assertEqual(len(commands), 2)
        self.assertEqual(commands[0][0:2], ["HyperDR", "model-input"])
        self.assertNotIn("--half-size", commands[0])
        self.assertTrue(commands[0][commands[0].index("--output") + 1].endswith(".f32"))
        self.assertIn("--input-report", commands[1])
        self.assertEqual(commands[1][commands[1].index("--gain-output") + 1], str(gain))
        self.assertEqual(commands[1][commands[1].index("--report") + 1], str(report))

    def test_raw_input_is_developed_at_half_size_without_jpeg(self):
        config = model.ModelConfig(
            root=Path("model"), python="python", script=Path("model/infer_gain.py"),
            checkpoint=Path("model/best.pt"), dataset_root=Path("dataset"),
            device="cpu", long_side=1024,
        )
        with tempfile.TemporaryDirectory() as directory:
            commands, _, _ = model.build_commands(
                config, Path("photo.arw"), Path(directory) / ".model", "HyperDR",
                "reconstruct")
        self.assertEqual(commands[0][0:2], ["HyperDR", "model-input"])
        self.assertIn("--highlight-recovery", commands[0])
        self.assertEqual(commands[0][commands[0].index("--highlight-recovery") + 1],
                         "reconstruct")
        self.assertIn("--half-size", commands[0])
        self.assertNotIn(".jpg", " ".join(part for command in commands for part in command))
        self.assertEqual(commands[1][0], "python")


class SettingsContractTest(unittest.TestCase):
    def test_settings_vocabulary_comes_from_the_converter(self):
        """The panel derives its settings from the schema, never a second copy.

        This used to be a regular-expression scrape of preset_keys() in
        src/cli.cpp, which only noticed a rename if the C++ still looked the way
        the pattern expected.
        """
        self.assertTrue(schema.ALL_KEYS)
        for key, entry in schema.SETTINGS.items():
            self.assertIn(entry["kind"], {"enum", "number", "integer", "boolean",
                                          "auto_or_number"}, key)
            self.assertTrue(entry["flag"].startswith("--"), key)
            self.assertIn("default", entry, key)

    def test_schema_file_matches_the_built_converter(self):
        """schema/settings.json is generated output; drift is a build error."""
        exe = detect_exe()
        if not exe:
            self.skipTest("no built HyperDR to compare against")
        emitted = subprocess.run([exe, "schema"], capture_output=True, timeout=30)
        self.assertEqual(emitted.returncode, 0, emitted.stderr.decode(errors="replace"))
        checked_in = schema.SCHEMA_PATH.read_text(encoding="utf-8")
        self.assertEqual(json.loads(emitted.stdout.decode("utf-8")),
                         json.loads(checked_in),
                         "schema/settings.json is stale: run "
                         "`HyperDR schema > schema/settings.json`")

    def test_validation_rejects_unknown_and_out_of_range(self):
        with self.assertRaises(ValueError):
            schema.validate({"contrst": 1.1})
        with self.assertRaises(ValueError):
            schema.validate({"contrast": 5.0})
        with self.assertRaises(ValueError):
            schema.validate({"contrast": "1.1"})
        with self.assertRaises(ValueError):
            schema.validate({"look": "cinematic"})
        with self.assertRaises(ValueError):
            schema.validate({"verify_output": "yes"})
        with self.assertRaises(ValueError):
            schema.validate({"headroom": "maximum"})
        self.assertEqual(schema.validate({"headroom": "auto"}), {"headroom": "auto"})

    def test_settings_use_the_cli_vocabulary(self):
        settings = options_to_settings(dict(BASE))
        self.assertIn("gain_strength", settings)
        self.assertIn("headroom_max", settings)
        self.assertNotIn("hdrStrength", settings)
        self.assertNotIn("hdrRange", settings)

    def test_settings_survive_a_json_round_trip(self):
        settings = options_to_settings(dict(BASE, contrast=1.15))
        text = json.dumps(settings, ensure_ascii=False)
        self.assertEqual(json.loads(text)["contrast"], 1.15)
        self.assertEqual(schema.validate(json.loads(text)), settings)


if __name__ == "__main__":
    unittest.main()
