"""WebGPU HDR preview must verify what the canvas actually configured."""
from __future__ import annotations

import shutil
import subprocess
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]


class WebGpuHdrContractTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.node = shutil.which("node")
        if not cls.node:
            raise unittest.SkipTest("Node is required for the WebGPU HDR contract test")

    def test_unconfirmed_extended_tone_mapping_is_rejected(self):
        runner = REPO_ROOT / "tests" / "js" / "gpu_hdr_runner.mjs"
        completed = subprocess.run(
            [self.node, str(runner)],
            text=True,
            capture_output=True,
            timeout=30,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)


if __name__ == "__main__":
    unittest.main()
