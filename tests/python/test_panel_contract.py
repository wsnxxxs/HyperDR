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

    def test_dual_source_uses_ten_bit_adaptive_base_and_negative_exposure(self):
        found = flags(build_argv("HyperDR", dict(
            BASE, sourceDomain="dual-rendition", brightness=-1.0)))
        self.assertEqual(found["--depth"], "10")
        self.assertEqual(found["--exposure-bias"], "-1")

    def test_color_options_reach_export_and_preview(self):
        options = dict(BASE, colorGamut="p3", clampSrgb=True)
        found = flags(build_argv("HyperDR", options))
        self.assertEqual(found["--color-gamut"], "p3")
        self.assertIn("--clamp-srgb", found)
        preview = flags(build_preview_frame_argv(
            "HyperDR", "photo.jpg", "preview.hpf", options, 1024))
        self.assertEqual(preview["--color-gamut"], "p3")
        self.assertIn("--clamp-srgb", preview)

    def test_sdr_output_gamut_ignores_stale_hdr_clamp(self):
        for encoding in ("sdr-jpeg", "sdr-tiff"):
            options = dict(BASE, encoding=encoding, outputGamut="p3", clampSrgb=True)
            for argv in (build_argv("HyperDR", options),
                         build_preview_frame_argv("HyperDR", "photo.jpg", "preview.hpf", options, 1024)):
                found = flags(argv)
                self.assertEqual(found["--output-gamut"], "p3")
                self.assertNotIn("--clamp-srgb", found)
        hdr = flags(build_argv("HyperDR", dict(BASE, outputGamut="p3", clampSrgb=True)))
        self.assertNotIn("--output-gamut", hdr)
        self.assertIn("--clamp-srgb", hdr)

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

    def test_fast_heic_export_is_explicit_and_format_specific(self):
        for encoding in ("adaptive", "pq", "hlg"):
            standard = flags(build_argv("HyperDR", dict(BASE, encoding=encoding)))
            fast = flags(build_argv(
                "HyperDR", dict(BASE, encoding=encoding, hevcPreset="medium")))
            self.assertNotIn("--hevc-preset", standard)
            self.assertEqual(fast["--hevc-preset"], "medium")
        for encoding in ("ultrahdr", "avif-pq", "avif-hlg", "sdr-jpeg"):
            self.assertNotIn("--hevc-preset", flags(build_argv(
                "HyperDR", dict(BASE, encoding=encoding, hevcPreset="medium"))))
        with self.assertRaises(ValueError):
            options_to_settings(dict(BASE, hevcPreset="fastest"))

    def test_bt2100_encodings_are_ten_bit(self):
        for encoding in ("pq", "hlg", "avif-pq", "avif-hlg"):
            found = flags(build_argv("HyperDR", dict(BASE, encoding=encoding)))
            self.assertEqual(found["--depth"], "10", encoding)
        for encoding in ("adaptive", "ultrahdr"):
            found = flags(build_argv("HyperDR", dict(BASE, encoding=encoding)))
            self.assertEqual(found["--depth"], "8", encoding)

    def test_hdr_sources_keep_a_ten_bit_adaptive_base(self):
        """A camera's 10-bit HDR survives its gain map only through a 10-bit base."""
        hdr = dict(BASE, sourceDomain="display-referred-hdr")
        self.assertEqual(flags(build_argv("HyperDR", dict(hdr, encoding="adaptive")))["--depth"],
                         "10")
        # The formats whose base is 8-bit by definition do not change.
        for encoding in ("ultrahdr", "sdr-jpeg"):
            self.assertEqual(
                flags(build_argv("HyperDR", dict(hdr, encoding=encoding)))["--depth"], "8",
                encoding)
        # SDR and RAW photographs keep the compatibility-first default.
        for domain in ("display-referred-sdr", "scene-referred", "", "nonsense"):
            found = flags(build_argv("HyperDR", dict(BASE, encoding="adaptive",
                                                      sourceDomain=domain)))
            self.assertEqual(found["--depth"], "8", domain)
        # The domain is a fact about the file, not a converter setting.
        self.assertNotIn("--source-domain", build_argv("HyperDR", dict(hdr)))

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
    def setUp(self):
        # Capability is cached per executable; a stale entry from another test
        # would make the model list look like it came from a different binary.
        model._MODEL_LIST_CACHE.clear()
        self.table = {
            "schema": "hyperdr.model-list/v1", "runtimeAvailable": True,
            "defaultModelId": "research-cnn-v1",
            "models": [{"id": name, "available": True} for name in
                       ("research-cnn-v1", "research-exif-v1")],
        }
        self.completed = subprocess.CompletedProcess(
            ["HyperDR"], 0, stdout=json.dumps(self.table).encode(), stderr=b"")

    def tearDown(self):
        model._MODEL_LIST_CACHE.clear()

    def test_disabled_model_does_not_probe_even_with_cached_capability(self):
        with mock.patch.object(model, "_native_executable", return_value="HyperDR"), \
                mock.patch.object(model.subprocess, "run", return_value=self.completed) as run:
            self.assertTrue(model.status()["ready"])
            for cached in (True, False):
                if not cached:
                    model._MODEL_LIST_CACHE.clear()
                run.reset_mock()
                with mock.patch.object(model, "_enabled", return_value=False):
                    state = model.status()
                    self.assertFalse(state["enabled"])
                    self.assertFalse(state["ready"])
                    for call in (model.model_list,
                                 lambda: model.resolve_model_id("nope"),
                                 lambda: model.native_model_gain(Path("missing.jpg"))):
                        with self.assertRaisesRegex(RuntimeError, "HYPERDR_MODEL_ENABLED"):
                            call()
                run.assert_not_called()

    def test_model_list_comes_from_the_executable(self):
        """The ids and the versions live in the binary, not in a Python copy."""
        table = {
            "schema": "hyperdr.model-list/v1",
            "runtimeAvailable": True,
            "defaultModelId": "research-cnn-v1",
            "models": [
                {"id": "research-cnn-v1", "available": True},
                {"id": "research-exif-v1", "available": True, "requiresExif": True,
                 "fallbackModelId": "research-cnn-v1"},
            ],
        }
        completed = subprocess.CompletedProcess(
            ["HyperDR"], 0, stdout=json.dumps(table).encode(), stderr=b"")
        with mock.patch.object(model, "_native_executable", return_value="HyperDR"), \
                mock.patch.object(model.subprocess, "run", return_value=completed) as run:
            status = model.status()
            model.model_list()
            run.assert_called_once()
        self.assertTrue(status["ready"])
        self.assertEqual(status["defaultModelId"], "research-cnn-v1")
        self.assertEqual([entry["id"] for entry in status["models"]],
                         ["research-cnn-v1", "research-exif-v1"])
        self.assertEqual(run.call_args.args[0][:3], ["HyperDR", "model-list", "--json"])

    def test_an_executable_without_the_list_is_not_supported(self):
        completed = subprocess.CompletedProcess([], 2, stdout=b"", stderr=b"unknown command: model-list")
        with mock.patch.object(model, "_native_executable", return_value="HyperDR"), \
                mock.patch.object(model.subprocess, "run", return_value=completed):
            self.assertFalse(model.status()["ready"])
            with self.assertRaises(RuntimeError):
                model.resolve_model_id(None)

    def test_failed_probes_are_not_legacy_capability_and_can_retry(self):
        failures = [
            subprocess.CompletedProcess([], 2, stdout=b"", stderr=b"fatal: failed to load weights"),
            subprocess.TimeoutExpired("model-list", 30),
            OSError("cannot launch converter"),
            subprocess.CompletedProcess([], 0, stdout=b"invalid json", stderr=b""),
            subprocess.CompletedProcess([], 0, stdout=b"[]", stderr=b""),
            subprocess.CompletedProcess([], 0, stdout=b'{"models":[]}', stderr=b""),
        ]
        for failure in failures:
            with self.subTest(failure=failure):
                model._MODEL_LIST_CACHE.clear()
                with mock.patch.object(model, "_native_executable", return_value="HyperDR"), \
                        mock.patch.object(model.subprocess, "run",
                                          side_effect=[failure, self.completed]) as run:
                    state = model.status()
                    self.assertFalse(state["ready"])
                    self.assertTrue(state["reason"])
                    self.assertEqual(state["models"], [])
                    self.assertEqual(state["modelListSource"], "probe-failed")
                    self.assertTrue(model.status()["ready"])
                    self.assertEqual(run.call_count, 2)

    def test_runtime_and_individual_model_availability_gate_selection(self):
        for runtime, available in ((False, True), (True, False), (None, True), (True, None)):
            with self.subTest(runtime=runtime, available=available):
                model._MODEL_LIST_CACHE.clear()
                table = {"runtimeAvailable": runtime, "defaultModelId": "research-cnn-v1",
                         "models": [{"id": "research-cnn-v1", "available": available}]}
                completed = subprocess.CompletedProcess(
                    [], 0, stdout=json.dumps(table).encode(), stderr=b"")
                with mock.patch.object(model, "_native_executable", return_value="HyperDR"), \
                        mock.patch.object(model.subprocess, "run", return_value=completed):
                    self.assertFalse(model.status()["ready"])
                    for requested in (None, "research-cnn-v1"):
                        with self.assertRaises(RuntimeError):
                            model.resolve_model_id(requested)
        model._MODEL_LIST_CACHE.clear()
        self.table["models"][0]["available"] = False
        completed = subprocess.CompletedProcess(
            [], 0, stdout=json.dumps(self.table).encode(), stderr=b"")
        with mock.patch.object(model, "_native_executable", return_value="HyperDR"), \
                mock.patch.object(model.subprocess, "run", return_value=completed):
            self.assertTrue(model.status()["ready"])
            self.assertEqual(model.resolve_model_id("research-exif-v1"), "research-exif-v1")
            for requested in (None, "research-cnn-v1"):
                with self.assertRaises(RuntimeError):
                    model.resolve_model_id(requested)

    def test_an_unknown_model_id_is_refused(self):
        with mock.patch.object(model, "_native_executable", return_value="HyperDR"), \
                mock.patch.object(model.subprocess, "run", return_value=self.completed):
            self.assertEqual(model.resolve_model_id("research-exif-v1"), "research-exif-v1")
            # An omitted id means this build's default, which is what a settings
            # file written before the selector contained.
            self.assertEqual(model.resolve_model_id(None), "research-cnn-v1")
            with self.assertRaises(ValueError):
                model.resolve_model_id("research-exif-v2")

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
                "requestedModelId": "research-exif-v1",
                "effectiveModelId": "research-cnn-v1",
                "modelVersion": "research-demo-fold0-seed908/v1",
                "inferenceMode": "pixel_only_fallback",
                "fallbackReason": "missing_capture_fields:iso",
                "baseOffsetNumerator": 1, "baseOffsetDenominator": 100000,
                "alternateOffsetNumerator": 1, "alternateOffsetDenominator": 100000,
            }, separators=(",", ":")).encode()
            packet = (model.NATIVE_MODEL_GAIN_MAGIC
                      + len(metadata).to_bytes(4, "little")
                      + metadata + b"\x00" * 8)
            completed = subprocess.CompletedProcess(
                ["HyperDR"], 0, stdout=packet, stderr=b"")
            with mock.patch.object(model, "_native_executable", return_value="HyperDR"), \
                    mock.patch.object(model.subprocess, "run",
                                      side_effect=[self.completed, completed]) as run:
                values, report = model.native_model_gain(source, "blend", "research-exif-v1")
            self.assertEqual(values, b"\x00" * 8)
            self.assertEqual(report["width"], 2)
            self.assertEqual(report["max_stops"], 1.5)
            # The report carries what ran, not what was asked for: a caller that
            # echoed its own request would label a fallback as a model-2 result.
            self.assertEqual(report["requested_model_id"], "research-exif-v1")
            self.assertEqual(report["effective_model_id"], "research-cnn-v1")
            self.assertEqual(report["inference_mode"], "pixel_only_fallback")
            self.assertEqual(report["fallback_reason"], "missing_capture_fields:iso")
            self.assertAlmostEqual(report["base_offset"], 1e-5)
            argv = run.call_args.args[0]
            self.assertEqual(argv[:3], ["HyperDR", "model-gain", str(source)])
            self.assertEqual(argv[argv.index("--ai-model") + 1], "research-exif-v1")
            self.assertNotIn("--color-gamut", argv)
            self.assertNotIn("--clamp-srgb", argv)
            self.assertEqual(list(Path(directory).iterdir()), [source])

    def test_model_and_color_options_distinguish_inference_requests(self):
        """Changing the model or its input/base must not join another prediction."""
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "photo.jpg"
            source.write_bytes(b"source")
            seen = []

            def record(argv, **_kwargs):
                if argv[1] == "model-list":
                    return self.completed
                seen.append(argv)
                metadata = json.dumps({
                    "schema": "hyperdr.native-model-gain/v1",
                    "width": 1, "height": 1, "channels": 1, "layout": "HW",
                    "sampleType": "float32-le", "scale": "signed-log2-gain",
                    "gainMaxStops": 1.0, "headroomStops": 1.0,
                }, separators=(",", ":")).encode()
                return subprocess.CompletedProcess(
                    argv, 0,
                    stdout=model.NATIVE_MODEL_GAIN_MAGIC
                    + len(metadata).to_bytes(4, "little") + metadata + b"\x00" * 4,
                    stderr=b"")

            with mock.patch.object(model, "_native_executable", return_value="HyperDR"), \
                    mock.patch.object(model.subprocess, "run", side_effect=record), \
                    mock.patch.object(model._INFERENCE_FLIGHT, "run",
                                      wraps=model._INFERENCE_FLIGHT.run) as flight:
                model._MODEL_LIST_CACHE.clear()
                model.native_model_gain(source, "blend", "research-cnn-v1")
                model.native_model_gain(source, "blend", "research-exif-v1")
                model.native_model_gain(source, "blend", "research-cnn-v1", color_gamut="p3")
                model.native_model_gain(source, "blend", "research-cnn-v1",
                                        color_gamut="p3", clamp_srgb=True)
                model.native_model_gain(source, "blend", "research-cnn-v1",
                                        color_gamut="rec2020", clamp_srgb=True)
                model.native_model_gain(source, "blend", "research-cnn-v1",
                                        color_gamut="rec2020", clamp_srgb=True)
            keys = [call.args[0] for call in flight.call_args_list]
            self.assertEqual(len(set(keys[:5])), 5)
            self.assertEqual(keys[4], keys[5])
            self.assertEqual([flags(argv)["--ai-model"] for argv in seen[:2]],
                             ["research-cnn-v1", "research-exif-v1"])
            self.assertNotIn("--color-gamut", seen[0])
            self.assertNotIn("--clamp-srgb", seen[2])
            self.assertEqual(flags(seen[2])["--color-gamut"], "p3")
            self.assertEqual(flags(seen[3])["--color-gamut"], "p3")
            self.assertIn("--clamp-srgb", seen[3])
            self.assertEqual(flags(seen[4])["--color-gamut"], "rec2020")


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

    def test_classic_tiff_headers_are_recognized(self):
        """The caller uses the RAW suffix before raster signature detection."""
        for header in (b"II*" + bytes(1) + b"a" * 60, b"MM" + bytes(1) + b"*" + b"b" * 60):
            self.assertEqual(formats.detect_format(header), "tiff")


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
                                          "auto_or_number", "string"}, key)
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
