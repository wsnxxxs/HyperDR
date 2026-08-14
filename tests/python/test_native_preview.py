from __future__ import annotations

import json
import os
import struct
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "apps" / "panel"))
STAGE = (
    REPO_ROOT / "apps" / "panel" / "web" / "js" / "preview" / "stage.js"
).read_text(encoding="utf-8")
MAIN = (
    REPO_ROOT / "apps" / "panel" / "web" / "js" / "main.js"
).read_text(encoding="utf-8")
SETTINGS_SCHEMA = (
    REPO_ROOT / "apps" / "panel" / "web" / "js" / "settings" / "schema.js"
).read_text(encoding="utf-8")
SCOPE = (
    REPO_ROOT / "apps" / "panel" / "web" / "js" / "preview" / "scope.js"
).read_text(encoding="utf-8")
GPU = (
    REPO_ROOT / "apps" / "panel" / "web" / "js" / "preview" / "gpu.js"
).read_text(encoding="utf-8")

from hyperdr_panel import native_preview  # noqa: E402
from hyperdr_panel.native_preview import parse_packet  # noqa: E402


def packet(status="ok", reasons=()):
    metadata = json.dumps({
        "schema": "hyperdr.native-preview/v1",
        "width": 2, "height": 1, "channels": 3,
        "layout": "HWC", "sampleType": "float32-le",
        "colorSpace": "linear-display-p3", "status": status,
        "degradationReasons": list(reasons),
    }, separators=(",", ":")).encode()
    # Two RGB planes. Values above one prove the contract does not clamp HDR.
    pixels = struct.pack("<12f", 0.1, 0.2, 0.3, 0.4, 0.5, 0.6,
                         0.2, 0.4, 1.5, 0.8, 1.2, 4.0)
    return b"HYPREV1\n" + len(metadata).to_bytes(4, "little") + metadata + pixels


class NativePreviewContractTests(unittest.TestCase):
    def setUp(self):
        native_preview._CACHE.clear()

    def tearDown(self):
        native_preview._CACHE.clear()

    def test_float_packet_preserves_linear_hdr_samples(self):
        data = packet()
        metadata = parse_packet(data)
        self.assertEqual(metadata["colorSpace"], "linear-display-p3")
        payload = data[12 + int.from_bytes(data[8:12], "little"):]
        self.assertGreater(max(struct.unpack("<12f", payload)), 1.0)

    def test_degraded_status_and_reason_are_not_lost(self):
        metadata = parse_packet(packet(
            "degraded", ["ultrahdr_decode_failed_sdr_fallback"]))
        self.assertEqual(metadata["status"], "degraded")
        self.assertEqual(metadata["degradationReasons"],
                         ["ultrahdr_decode_failed_sdr_fallback"])

    def test_truncated_planes_are_rejected(self):
        with self.assertRaisesRegex(ValueError, "truncated"):
            parse_packet(packet()[:-4])

    def test_same_size_timestamp_preserved_replacement_invalidates_cache(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "photo.jpg"
            source.write_bytes(b"first")
            original_stat = source.stat()
            builds = []

            def build(path, _options, _edge):
                builds.append(path.read_bytes())
                return packet(), {"width": 2, "height": 1}

            with mock.patch.object(native_preview, "_build", build):
                native_preview.preview_for(source, {}, 960)
                source.write_bytes(b"other")
                os.utime(source, ns=(original_stat.st_atime_ns,
                                     original_stat.st_mtime_ns))
                native_preview.preview_for(source, {}, 960)
            self.assertEqual(builds, [b"first", b"other"])

    def test_failed_cli_removes_atomic_temporary_artifacts(self):
        seen_output = None

        def failed(argv, **_kwargs):
            nonlocal seen_output
            seen_output = Path(argv[argv.index("--output") + 1])
            Path(str(seen_output) + ".tmp.123.0").write_bytes(b"partial")
            return mock.Mock(returncode=1, stderr=b"failed")

        with mock.patch.object(native_preview, "detect_exe", return_value="HyperDR"), \
                mock.patch.object(native_preview.subprocess, "run", failed):
            with self.assertRaisesRegex(ValueError, "failed"):
                native_preview._build(Path("photo.jpg"), {}, 960)
        self.assertIsNotNone(seen_output)
        self.assertFalse(seen_output.exists())
        self.assertEqual(list(seen_output.parent.glob(seen_output.name + ".tmp.*")), [])

    def test_old_crash_orphans_are_swept_without_touching_live_preview(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            orphan = folder / "hyperdr-preview-old.hpf.tmp.12.0"
            live = folder / "hyperdr-preview-live.hpf"
            unrelated = folder / "somebody-else.hpf"
            for path in (orphan, live, unrelated):
                path.write_bytes(b"x")
            now = 10_000.0
            old = now - native_preview._ORPHAN_MAX_AGE_SECONDS - 1
            os.utime(orphan, (old, old))
            os.utime(unrelated, (old, old))
            with mock.patch.object(native_preview.tempfile, "gettempdir",
                                   return_value=temporary):
                native_preview._cleanup_orphaned_previews(now)
            self.assertFalse(orphan.exists())
            self.assertTrue(live.exists())
            self.assertTrue(unrelated.exists())


class NativePreviewFrontendContractTests(unittest.TestCase):
    def test_image_adjustments_reset_to_point_six_ev_without_persistence(self):
        self.assertIn("export const DEFAULT_BRIGHTNESS_EV = 0.6;", SETTINGS_SCHEMA)
        self.assertIn("default: DEFAULT_BRIGHTNESS_EV", SETTINGS_SCHEMA)
        self.assertIn('export const PERSISTED_OPTION_KEYS = ["encoding"];', SETTINGS_SCHEMA)
        self.assertIn("store.watchAny(PERSISTED_OPTION_KEYS, persistSettings)", MAIN)
        self.assertIn("...defaultSettings(store.get().encoding)", STAGE)

    def test_native_float_planes_do_not_use_retired_sdr_display_buffers(self):
        self.assertIn("image.frame = preview;", STAGE)
        self.assertIn("image.source = planeToImageData(preview.base", STAGE)
        for retired in ("displayMapped(", "image.display", "image.output"):
            self.assertNotIn(retired, STAGE)

    def test_histogram_compares_native_base_and_rendered_planes(self):
        self.assertIn("export function analyse(source, rendered = null)", SCOPE)
        self.assertIn("histogramFromPlane(frame.base", SCOPE)
        self.assertIn("histogramFromPlane(frame.hdr", SCOPE)
        for retired in ("scene.data", "sceneScale", "simulateOutput(",
                        "simulateModelOutput("):
            self.assertNotIn(retired, SCOPE)

    def test_transient_preview_failures_keep_the_last_valid_frame(self):
        self.assertIn("if (error.status === 404)", STAGE)
        self.assertIn("if (!image.frame)", STAGE)
        self.assertIn("toast(message, true)", STAGE)
        self.assertIn("error.status === 409", STAGE)

    def test_original_comparison_layer_is_cached_across_look_reloads(self):
        self.assertIn("original: null", STAGE)
        self.assertIn("if (resetOriginal || !image.original)", STAGE)
        self.assertIn("originalContext.putImageData(image.original", STAGE)
        self.assertIn("renderer.draw(null, { original: false })", STAGE)

    def test_hdr_capability_probe_never_targets_the_visible_swap_chain(self):
        self.assertIn("const probeTexture = device.createTexture", GPU)
        self.assertIn("view: probeTexture.createView()", GPU)
        self.assertNotIn("const canvasTexture = context.getCurrentTexture()", GPU)


if __name__ == "__main__":
    unittest.main()
