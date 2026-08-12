from __future__ import annotations

import json
import struct
import sys
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "apps" / "panel"))

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


if __name__ == "__main__":
    unittest.main()
