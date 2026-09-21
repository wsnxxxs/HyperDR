"""Deployment resume must preserve and validate the producing configuration."""
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import numpy as np

SCRIPT = Path(__file__).resolve().parents[2] / "HyperDR_Model/scripts/build_deployment_cache.py"
spec = importlib.util.spec_from_file_location("deployment_cache_test_target", SCRIPT)
cache = importlib.util.module_from_spec(spec)
# These tests do not request paired targets, the only operation using OpenCV.
with patch.dict(sys.modules, {"cv2": SimpleNamespace()}):
    spec.loader.exec_module(cache)


class DeploymentCacheTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.originals = self.root / "originals"
        self.originals.mkdir()
        self.source = self.originals / "photo.raw"
        self.source.write_bytes(b"original")
        self.exe = self.root / "HyperDR"
        self.exe.write_bytes(b"generator")
        self.output = self.root / "output"
        self.fallback = self.root / "fallback"
        self.fallback.mkdir()
        (self.fallback / "photo.png").write_bytes(b"fallback")
        self.calls = []
        self.fail_original = False

    def run_native(self, command, **kwargs):
        self.calls.append(command)
        if self.fail_original and Path(command[2]) == self.source:
            return SimpleNamespace(returncode=1, stdout="", stderr="unsupported RAW")
        raw = Path(command[command.index("--output") + 1])
        report = Path(command[command.index("--report") + 1])
        np.full((2, 2, 3), 0.25, dtype="<f4").tofile(raw)
        report.write_text(json.dumps({"schema": "hyperdr.model-input/v1",
            "geometry": {"resize_convention": "test-area/v2"},
            "pixel_file": {"width": 2, "height": 2, "layout": "HWC",
                           "color_space": "linear Display P3"}}))
        return SimpleNamespace(returncode=0, stdout="", stderr="")

    def run_cache(self, *extra, output=None):
        directory = output or self.output
        argv = [str(SCRIPT), "--dataset-root", str(self.root), "--hyperdr-exe", str(self.exe),
                "--output-dir", str(directory), *extra]
        with patch.object(sys, "argv", argv), patch.object(cache, "sample_ids", return_value=["photo"]), \
                patch.object(cache.subprocess, "run", side_effect=self.run_native), patch("builtins.print"):
            cache.main()
        return json.loads((directory / "deployment-cache.jsonl").read_text())

    def test_resume_preserves_complete_provenance(self):
        first = self.run_cache()
        second = self.run_cache("--resume")
        third = self.run_cache("--resume")
        self.assertEqual(len(self.calls), 1)
        for key in ("source", "source_sha256", "original_source_sha256", "generation",
                    "tensor_sha256", "model_input_report"):
            self.assertEqual(first[key], second[key])
            self.assertEqual(second[key], third[key])
        self.assertTrue(third["reused"])

    def test_resume_rebuilds_changed_inputs_and_settings(self):
        self.run_cache()
        self.source.write_bytes(b"new original")
        self.assertFalse(self.run_cache("--resume")["reused"])
        self.exe.write_bytes(b"new generator")
        self.assertFalse(self.run_cache("--resume")["reused"])
        self.assertFalse(self.run_cache("--resume", "--long-side", "512")["reused"])
        flags = ("--resume", "--long-side", "512", "--highlight-recovery", "clip")
        self.assertFalse(self.run_cache(*flags)["reused"])
        (self.output / "photo.npy").write_bytes(b"corrupt tensor")
        self.assertFalse(self.run_cache(*flags)["reused"])
        manifest = self.output / "deployment-cache.jsonl"
        row = json.loads(manifest.read_text())
        del row["generation"]
        manifest.write_text(json.dumps(row) + "\n")
        self.assertFalse(self.run_cache(*flags)["reused"])
        self.assertEqual(len(self.calls), 7)

    def test_reuse_directory_validates_manifest_and_retains_report(self):
        first = self.run_cache()
        reused = self.run_cache("--reuse-input-dir", str(self.output), output=self.root / "copy")
        self.assertTrue(reused["reused"])
        self.assertEqual(first["model_input_report"], reused["model_input_report"])
        self.assertEqual(len(self.calls), 1)
        self.exe.write_bytes(b"changed executable")
        rebuilt = self.run_cache("--reuse-input-dir", str(self.output), output=self.root / "rebuilt")
        self.assertFalse(rebuilt["reused"])
        self.assertEqual(len(self.calls), 2)

    def test_fallback_checks_actual_source_and_preserves_failure(self):
        self.fail_original = True
        flags = ("--fallback-sdr-dir", str(self.fallback))
        first = self.run_cache(*flags)
        resumed = self.run_cache("--resume", *flags)
        self.assertEqual(len(self.calls), 2)
        self.assertEqual(resumed["source"], str(self.fallback / "photo.png"))
        self.assertEqual(first["original_decode_error"], resumed["original_decode_error"])
        (self.fallback / "photo.png").write_bytes(b"changed fallback")
        self.assertFalse(self.run_cache("--resume", *flags)["reused"])
        self.assertEqual(len(self.calls), 4)


if __name__ == "__main__":
    unittest.main()
