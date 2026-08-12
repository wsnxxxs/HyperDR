"""The preview honours the RAW decode settings.

The panel's highlight-recovery control looked inert for a long time, and the
reason was here rather than in the C++: a RAW preview was lifted straight out of
the file's embedded JPEG, so it never went through LibRaw and no decode setting
could reach it. These cases pin the three links that were missing -- the flag is
on the command line, the cache tells two modes apart, and the endpoint refuses a
mode the converter does not have -- because each one failed silently.
"""
from __future__ import annotations

import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "apps" / "panel"))

from hyperdr_panel import api, session, thumbnail  # noqa: E402

JPEG = b"\xff\xd8\xff" + b"x" * 64


class ThumbnailCommandTests(unittest.TestCase):
    """What reaches the converter."""

    def setUp(self):
        self.calls: list[list[str]] = []

    def _fake_run(self, argv, **kwargs):
        self.calls.append(list(argv))
        output = Path(argv[argv.index("--output") + 1])
        # A 1x1 JPEG header is enough for `jpeg_dimensions` to succeed.
        output.write_bytes(
            b"\xff\xd8\xff\xc0\x00\x11\x08\x00\x01\x00\x01"
            + b"\x03\x01\x22\x00\x02\x11\x01\x03\x11\x01\xff\xd9")
        return mock.Mock(returncode=0, stderr=b"",
                         stdout=b'{"scale":1,"exposure":0.75}\n')

    def _thumbnail(self, name: str, mode: str) -> list[str]:
        self.calls.clear()
        with mock.patch.object(thumbnail, "detect_exe", lambda: "HyperDR"), \
                mock.patch.object(thumbnail.subprocess, "run", self._fake_run):
            thumbnail._converter_thumbnail(Path(name), mode, 960)
        return self.calls[0]

    def test_the_chosen_highlight_recovery_is_on_the_command_line(self):
        argv = self._thumbnail("photo.arw", "reconstruct")
        self.assertIn("--highlight-recovery", argv)
        self.assertEqual(argv[argv.index("--highlight-recovery") + 1], "reconstruct")
        self.assertEqual(argv[argv.index("--max-edge") + 1], "960")

    def test_raw_previews_decode_at_half_size(self):
        # The preview is bounded by MAX_EDGE anyway, so half-size demosaic costs
        # nothing visible and is the reason a real RAW decode is affordable here.
        self.assertIn("--half-size", self._thumbnail("photo.arw", "blend"))

    def test_non_raw_previews_do_not_ask_for_half_size(self):
        self.assertNotIn("--half-size", self._thumbnail("photo.jpg", "blend"))

    def test_converter_metadata_reaches_the_thumbnail_result(self):
        with mock.patch.object(thumbnail, "detect_exe", lambda: "HyperDR"), \
                mock.patch.object(thumbnail.subprocess, "run", self._fake_run):
            _, dimensions, scale, exposure = thumbnail._converter_thumbnail(
                Path("photo.arw"), "blend", 960)
        self.assertEqual(dimensions, (1, 1))
        self.assertEqual(scale, 1.0)
        self.assertEqual(exposure, 0.75)


class ThumbnailCacheTests(unittest.TestCase):
    """Two modes are two images, and the cache has to know it."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.source = Path(self.temporary.name) / "photo.arw"
        self.source.write_bytes(b"\x00" * 32)
        thumbnail._CACHE.clear()
        self.modes: list[str] = []

    def tearDown(self):
        thumbnail._CACHE.clear()
        self.temporary.cleanup()

    def _build(self, source, highlight_recovery, max_edge):
        self.modes.append(highlight_recovery)
        return (b"jpeg-" + highlight_recovery.encode() + str(max_edge).encode(),
                (4, 4), 1.0, 0.0)

    def test_each_highlight_mode_gets_its_own_cache_entry(self):
        with mock.patch.object(thumbnail, "_converter_thumbnail", self._build):
            first = thumbnail.thumbnail_for(self.source, "blend")
            second = thumbnail.thumbnail_for(self.source, "reconstruct")
            again = thumbnail.thumbnail_for(self.source, "blend")

        suffix = str(thumbnail.MAX_EDGE).encode()
        self.assertEqual(first[0], b"jpeg-blend" + suffix)
        self.assertEqual(second[0], b"jpeg-reconstruct" + suffix)
        # The repeat is served from the cache rather than decoded a third time.
        self.assertEqual(again[0], b"jpeg-blend" + suffix)
        self.assertEqual(self.modes, ["blend", "reconstruct"])

    def test_preview_size_is_part_of_the_cache_key(self):
        with mock.patch.object(thumbnail, "_converter_thumbnail", self._build):
            small = thumbnail.thumbnail_for(self.source, "blend", 960)
            large = thumbnail.thumbnail_for(self.source, "blend", 1280)
            again = thumbnail.thumbnail_for(self.source, "blend", 960)

        self.assertEqual(small[0], b"jpeg-blend960")
        self.assertEqual(large[0], b"jpeg-blend1280")
        self.assertEqual(again[0], small[0])
        self.assertEqual(self.modes, ["blend", "blend"])

    def test_same_size_timestamp_preserved_replacement_invalidates_cache(self):
        original_stat = self.source.stat()
        with mock.patch.object(thumbnail, "_converter_thumbnail", self._build):
            thumbnail.thumbnail_for(self.source, "blend")
            self.source.write_bytes(b"\x01" * 32)
            os.utime(self.source, ns=(original_stat.st_atime_ns,
                                      original_stat.st_mtime_ns))
            thumbnail.thumbnail_for(self.source, "blend")
        self.assertEqual(self.modes, ["blend", "blend"])


class PreviewEndpointTests(unittest.TestCase):
    """What the browser is allowed to ask for."""

    @staticmethod
    def _native_result(data=b"HYPREV1\nfloat-planes", *, status="ok", reasons=None):
        return data, {
            "width": 2,
            "height": 2,
            "status": status,
            "degradationReasons": list(reasons or []),
        }

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.previous_root = session.WORK_ROOT
        session.WORK_ROOT = Path(self.temporary.name).resolve()
        self.context = api.Context(output_selections={})
        self.session_id = session.create_session()
        (session.session_dir(self.session_id, "input") / "photo.jpg").write_bytes(JPEG)

    def tearDown(self):
        session.WORK_ROOT = self.previous_root
        self.temporary.cleanup()

    def test_the_mode_reaches_the_thumbnail(self):
        seen = {}

        def fake(source, highlight_recovery, max_edge):
            seen["mode"] = highlight_recovery
            seen["edge"] = max_edge
            return self._native_result()

        with mock.patch.object(api, "thumbnail_for", fake):
            response = api.preview(self.context, {
                "id": [self.session_id], "hr": ["unclip"], "edge": ["960"]})
        self.assertEqual(response.status, 200)
        self.assertEqual(seen["mode"], "unclip")
        self.assertEqual(seen["edge"], 960)

    def test_an_omitted_mode_falls_back_to_the_panel_default(self):
        seen = {}

        def fake(source, highlight_recovery, max_edge):
            seen["mode"] = highlight_recovery
            return self._native_result()

        with mock.patch.object(api, "thumbnail_for", fake):
            api.preview(self.context, {"id": [self.session_id]})
        self.assertEqual(seen["mode"], thumbnail.DEFAULT_HIGHLIGHT_RECOVERY)

    def test_an_unknown_mode_is_refused_rather_than_passed_through(self):
        response = api.preview(self.context, {"id": [self.session_id], "hr": ["--rm-rf"]})
        self.assertEqual(response.status, 400)
        self.assertIn("highlight recovery", response.payload["error"])

    def test_an_oversized_preview_is_refused(self):
        response = api.preview(
            self.context, {"id": [self.session_id], "edge": [str(thumbnail.MAX_EDGE + 1)]})
        self.assertEqual(response.status, 400)
        self.assertIn("preview edge", response.payload["error"])

    def test_the_native_hdr_packet_reaches_the_browser_without_8_bit_scaling(self):
        packet = b"HYPREV1\nlinear-p3-float-planes"
        with mock.patch.object(
                api, "thumbnail_for",
                lambda source, mode, edge: self._native_result(packet)):
            response = api.preview(self.context, {"id": [self.session_id]})
        self.assertEqual(response.status, 200)
        self.assertEqual(response.body, packet)
        self.assertEqual(response.content_type, "application/vnd.hyperdr.preview")
        self.assertNotIn("X-Preview-Scale", response.headers)
        self.assertNotIn("X-Preview-Exposure", response.headers)

    def test_a_native_preview_reports_its_status_and_degradation(self):
        with mock.patch.object(
                api, "thumbnail_for",
                lambda source, mode, edge: self._native_result(
                    status="degraded", reasons=["embedded-preview-only"])):
            response = api.preview(self.context, {"id": [self.session_id]})
        self.assertEqual(response.status, 200)
        self.assertEqual(response.headers["X-Preview-Status"], "degraded")
        self.assertEqual(
            response.headers["X-Preview-Degradation-Reasons"],
            "embedded-preview-only")

    def test_every_converter_mode_is_accepted(self):
        # Validated against the converter's own schema, so a mode added to the
        # C++ enum cannot be left rejected here.
        with mock.patch.object(
                api, "thumbnail_for",
                lambda source, mode, edge: self._native_result()):
            for mode in api._HIGHLIGHT_RECOVERY_CHOICES:
                response = api.preview(self.context, {"id": [self.session_id], "hr": [mode]})
                self.assertEqual(response.status, 200, mode)


if __name__ == "__main__":
    unittest.main()


class ScaleParsingTests(unittest.TestCase):
    """What the converter says about the preview's headroom, and what is ignored."""

    def test_a_reported_scale_is_read(self):
        self.assertEqual(thumbnail._parse_scale(b'{"scale":8}\n'), 8.0)

    def test_silence_means_no_scaling(self):
        # A converter predating the field leaves the preview clipped exactly as
        # it used to be, rather than being multiplied by a number nobody sent.
        self.assertEqual(thumbnail._parse_scale(b""), 1.0)
        self.assertEqual(thumbnail._parse_scale(b"not json"), 1.0)
        self.assertEqual(thumbnail._parse_scale(b"{}"), 1.0)

    def test_an_implausible_scale_is_refused(self):
        self.assertEqual(thumbnail._parse_scale(b'{"scale":0}'), 1.0)
        self.assertEqual(thumbnail._parse_scale(b'{"scale":1e9}'), 1.0)
        self.assertEqual(thumbnail._parse_scale(b'{"scale":"eight"}'), 1.0)

    def test_raw_exposure_is_read_and_bounded(self):
        self.assertEqual(thumbnail._parse_exposure(b'{"exposure":1.5}'), 1.5)
        self.assertEqual(thumbnail._parse_exposure(b'{"exposure":-2}'), -2.0)
        self.assertEqual(thumbnail._parse_exposure(b'{"exposure":99}'), 0.0)
        self.assertEqual(thumbnail._parse_exposure(b'{"exposure":"auto"}'), 0.0)
