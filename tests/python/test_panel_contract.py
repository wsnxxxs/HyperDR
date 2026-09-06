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
from unittest import mock

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "apps" / "panel"))

from hyperdr_panel import formats  # noqa: E402
from hyperdr_panel import schema  # noqa: E402
from hyperdr_panel import model  # noqa: E402
from hyperdr_panel.command import (  # noqa: E402
    build_argv,
    build_curve_argv,
    build_preview_frame_argv,
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
        self.assertEqual(found["--pop"], "0")
        self.assertEqual(found["--exposure-bias"], "0.6")
        self.assertNotIn("--color-gamut", found)
        self.assertNotIn("--clamp-srgb", found)

    def test_color_options_reach_export_and_preview(self):
        options = dict(BASE, colorGamut="p3", clampSrgb=True)
        found = flags(build_argv("HyperDR", options))
        self.assertEqual(found["--color-gamut"], "p3")
        self.assertIn("--clamp-srgb", found)
        preview = flags(build_preview_frame_argv(
            "HyperDR", "photo.jpg", "preview.hpf", options, 1024))
        self.assertEqual(preview["--color-gamut"], "p3")
        self.assertIn("--clamp-srgb", preview)

    def test_explicit_default_color_gamut_is_visible(self):
        found = flags(build_argv("HyperDR", dict(BASE, colorGamut="srgb")))
        self.assertEqual(found["--color-gamut"], "srgb")

    def test_color_options_validate(self):
        with self.assertRaises(ValueError):
            options_to_settings(dict(BASE, colorGamut="rec709"))
        with self.assertRaises(ValueError):
            options_to_settings(dict(BASE, clampSrgb="true"))

    def test_panel_options_are_not_silently_coerced(self):
        for options in ({"quality": 90.9}, {"contrast": "1.2"},
                        {"highlightRecovery": "nope"}):
            with self.assertRaises(ValueError, msg=str(options)):
                options_to_settings(options)

    def test_the_renderer_is_fixed_and_a_stale_client_cannot_change_it(self):
        """The renderer decides which curve the browser draws, so a client cannot pick it."""
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

    def test_strength_does_not_change_photographic_style(self):
        found = flags(build_argv("HyperDR", dict(BASE, hdrStrength=0.6, hdrRange=3.0)))
        self.assertEqual(found["--gain-strength"], "0.6")
        self.assertEqual(found["--pop"], "0")
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

    def test_ai_post_adjustments_are_model_only_and_reach_native_cli(self):
        options = dict(
            BASE,
            _model_mode=True,
            hdrStrength=0.65,
            aiBrightness=0.25,
            aiContrast=1.2,
            aiShadows=-0.3,
            aiHighlights=0.4,
            aiHdrRange=2.8,
            aiExpansionStart=0.55,
        )
        found = flags(build_argv("HyperDR", options))
        self.assertEqual(found["--ai-model"], "embedded")
        self.assertEqual(found["--gain-strength"], "0.65")
        expected = {
            "--ai-brightness": "0.25",
            "--ai-contrast": "1.2",
            "--ai-shadows": "-0.3",
            "--ai-highlights": "0.4",
            "--ai-hdr-range": "2.8",
            "--ai-expansion-start": "0.55",
        }
        for flag, value in expected.items():
            self.assertEqual(found[flag], value)

        # A stale AI snapshot must not change manual-mode argv at all.
        manual = flags(build_argv(
            "HyperDR", dict(BASE, aiBrightness=0.9, aiContrast=1.3)))
        for flag in expected:
            self.assertNotIn(flag, manual)
        for flag in ("--look", "--contrast", "--vibrance", "--pop",
                     "--headroom-max", "--exposure-bias", "--expansion-start",
                     "--area-coverage", "--exposure", "--headroom"):
            self.assertNotIn(flag, found, flag)

    def test_ai_post_adjustments_validate_encoding_headroom(self):
        with self.assertRaises(ValueError):
            build_argv("HyperDR", dict(
                BASE,
                encoding="hlg",
                _model_mode=True,
                aiHdrRange=2.5,
            ))

    def test_native_model_preview_omits_manual_development_flags(self):
        found = flags(build_preview_frame_argv(
            "HyperDR", "photo.jpg", "preview.hpf",
            dict(BASE, _model_mode=True, hdrStrength=0.7,
                 brightness=0.6, contrast=1.08, vibrance=0.12,
                 hdrRange=2.5, expansionStart=0.25, areaCoverage=1.0),
            1024))
        self.assertEqual(found["--ai-model"], "embedded")
        self.assertEqual(found["--gain-strength"], "0.7")
        for flag in ("--look", "--contrast", "--vibrance", "--pop",
                     "--headroom-max", "--exposure-bias", "--expansion-start",
                     "--area-coverage", "--exposure", "--headroom"):
            self.assertNotIn(flag, found, flag)

    def test_native_model_ignores_stale_manual_hdr_ceiling(self):
        found = flags(build_argv(
            "HyperDR", dict(BASE, _model_mode=True, encoding="hlg",
                             hdrRange=4.0, brightness=0.6,
                             expansionStart=0.75)))
        self.assertEqual(found["--ai-model"], "embedded")
        self.assertEqual(found["--ai-hdr-range"], "-1")

    def test_native_preview_reuses_a_decode_cache(self):
        argv = build_preview_frame_argv(
            "HyperDR", "photo.arw", "preview.hpf", {}, 2048,
            decode_cache="work/.decode-cache", source_digest="abc123")
        found = flags(argv)
        self.assertEqual(found["--decode-cache"],
                         "work/.decode-cache")
        self.assertEqual(found["--decode-cache-source-sha256"], "abc123")
        self.assertIn("--fast-preview", found)


class ModelIntegrationTest(unittest.TestCase):
    def test_status_uses_native_switch_and_executable_only(self):
        with mock.patch.object(model, "_native_executable", return_value="HyperDR"), \
                mock.patch.object(model, "_enabled", return_value=True):
            self.assertTrue(model.status()["ready"])
        with mock.patch.object(model, "_enabled", return_value=False):
            state = model.status()
            self.assertFalse(state["enabled"])
            self.assertFalse(state["ready"])

    def test_native_packet_is_decoded_without_writing_model_sidecars(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "photo.jpg"
            source.write_bytes(b"source")
            metadata = json.dumps({
                "schema": "hyperdr.native-model-gain/v1",
                "width": 2, "height": 1, "channels": 1,
                "layout": "HW", "sampleType": "float32-le",
                "scale": "signed-log2-gain", "gainMaxStops": 1.5,
                "headroomStops": 1.5,
            }, separators=(",", ":")).encode()
            packet = (model.NATIVE_MODEL_GAIN_MAGIC
                      + len(metadata).to_bytes(4, "little")
                      + metadata + b"\x00" * 8)
            completed = subprocess.CompletedProcess(
                ["HyperDR"], 0, stdout=packet, stderr=b"")
            with mock.patch.object(model, "_native_executable", return_value="HyperDR"), \
                    mock.patch.object(model.subprocess, "run", return_value=completed) as run:
                values, report = model.native_model_gain(source, "blend")
            self.assertEqual(values, b"\x00" * 8)
            self.assertEqual(report["width"], 2)
            self.assertEqual(report["max_stops"], 1.5)
            argv = run.call_args.args[0]
            self.assertEqual(argv[:5], ["HyperDR", "model-gain", str(source),
                                        "--ai-model", "embedded"])
            self.assertEqual(list(Path(directory).iterdir()), [source])


class InputVocabularyTest(unittest.TestCase):
    """The panel's formats come from the converter, not from a second copy."""

    def test_extensions_and_signatures_are_derived_from_the_schema(self):
        inputs = schema.DOCUMENT["inputs"]
        self.assertEqual(formats.RAW_INPUT_EXTENSIONS,
                         frozenset(inputs["extensions"]["raw"]))
        flattened = frozenset(
            extension
            for family in inputs["extensions"]["raster"].values()
            for extension in family)
        self.assertEqual(formats.RASTER_INPUT_EXTENSIONS, flattened)
        self.assertEqual(formats.SUPPORTED_EXTENSIONS,
                         formats.RAW_INPUT_EXTENSIONS | flattened)
        self.assertTrue(formats.PREFIX_BYTES >= 16)

    def test_every_raster_family_has_a_canonical_extension(self):
        for family in schema.DOCUMENT["inputs"]["extensions"]["raster"]:
            self.assertIn(family, formats.CANONICAL_EXTENSIONS, family)
            self.assertIn(formats.CANONICAL_EXTENSIONS[family],
                          formats.RASTER_INPUT_EXTENSIONS, family)

    def test_a_raw_header_is_never_named_as_a_raster(self):
        """Most RAW containers are TIFF; only LibRaw can validate the file."""
        for header in (b"II*" + bytes(1) + b"a" * 60, b"MM" + bytes(1) + b"*" + b"b" * 60):
            self.assertIsNone(formats.detect_format(header))


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
