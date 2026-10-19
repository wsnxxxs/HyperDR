"""Exercise the standalone ISO-strip tool through the shipping XMP reader."""
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
        executable = os.environ.get("HYPERDR_EXECUTABLE")
        if not executable:
            self.skipTest("requires the native test entry point")
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
            inspection = json.loads(subprocess.check_output([executable, "inspect", str(derived), "--json"]))
            self.assertEqual(inspection["reader_path"], "xmp-imageio")
            self.assertFalse(inspection["mpf_repaired"])
            self.assertEqual(inspection["alternate_headroom"], 2)
            probe = json.loads(subprocess.check_output([executable, "probe", str(derived)]))
            self.assertEqual(probe["inputDomain"], "dual-rendition")
            self.assertFalse(probe["degraded"])
