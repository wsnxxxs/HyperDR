"""Exercise the standalone ISO-strip tool through the shipping XMP reader."""
import ctypes
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class GainMapStripTest(unittest.TestCase):
    def test_stripped_fixture_keeps_pixels_and_has_valid_directory_and_mpf(self):
        library_path = os.environ.get("HYPERDR_LIBRARY")
        if not library_path:
            self.skipTest("requires the native C ABI library")
        library = ctypes.CDLL(library_path)
        pointer = ctypes.c_void_p
        library.hyperdr_engine_create.argtypes = [ctypes.c_char_p, ctypes.POINTER(pointer), ctypes.POINTER(pointer)]
        library.hyperdr_probe.argtypes = [pointer, ctypes.c_char_p, ctypes.POINTER(pointer), ctypes.POINTER(pointer)]
        library.hyperdr_capabilities.argtypes = [pointer, ctypes.POINTER(pointer), ctypes.POINTER(pointer)]
        library.hyperdr_engine_destroy.argtypes = [pointer]
        library.hyperdr_string_free.argtypes = [pointer]
        fixture = ROOT / "tests/fixtures/gain-map-jpeg/xmp-and-iso.jpg"
        with tempfile.TemporaryDirectory(prefix="build-strip-test-", dir=ROOT) as temporary:
            derived = Path(temporary) / "xmp-only.jpg"
            checks = json.loads(subprocess.check_output([
                sys.executable, str(ROOT / "tests/tools/strip_iso_segments.py"),
                str(fixture), str(derived)]))
            for field in ("primary_compressed_payload_identical", "gain_compressed_payload_identical",
                          "primary_non_iso_except_mpf_item_length_identical", "gain_non_iso_identical",
                          "trailer_identical", "item_length_verified", "mpf_recomputed"):
                self.assertTrue(checks[field], field)
            self.assertEqual(checks["item_length_recomputed"], 1)
            self.assertEqual(checks["iso_segments_remaining"], 0)
            engine, output, error = pointer(), pointer(), pointer()
            self.assertEqual(library.hyperdr_engine_create(b'{"hevc_override":"unavailable"}', ctypes.byref(engine), ctypes.byref(error)), 0)
            try:
                self.assertEqual(library.hyperdr_capabilities(engine, ctypes.byref(output), ctypes.byref(error)), 0)
                capabilities = json.loads(ctypes.string_at(output))
                library.hyperdr_string_free(output)
                output = pointer()
                if not capabilities["codecs"]:
                    self.skipTest("strip invariants passed; XMP decoding requires a codec-enabled build")
                self.assertEqual(library.hyperdr_probe(engine, os.fsencode(derived), ctypes.byref(output), ctypes.byref(error)), 0)
                probe = json.loads(ctypes.string_at(output))
            finally:
                library.hyperdr_string_free(output)
                library.hyperdr_engine_destroy(engine)
            self.assertEqual(probe["inputDomain"], "dual-rendition")
            self.assertFalse(probe["degraded"])
