"""Cross-language guard for the browser's local photographic curve.

The live preview deliberately no longer fetches a curve while a slider moves.
These tests compare every locally generated LUT sample with the C++ command so
that changing either implementation cannot silently make preview and export
diverge.
"""
from __future__ import annotations

import json
import shutil
import subprocess
import sys
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "apps" / "panel"))

from hyperdr_panel.command import build_curve_argv  # noqa: E402
from hyperdr_panel.executable import detect_exe  # noqa: E402


CASES = [
    {"contrast": 1.08, "hdrRange": 2.5, "expansionStart": 0.25,
     "areaCoverage": 1.0, "samples": 257},
    {"contrast": 0.80, "hdrRange": 0.0, "expansionStart": 0.18,
     "areaCoverage": 0.0, "samples": 257},
    {"contrast": 1.35, "hdrRange": 4.0, "expansionStart": 0.75,
     "areaCoverage": 0.35, "samples": 257},
    {"contrast": 1.17, "hdrRange": 2.3, "expansionStart": 0.48,
     "areaCoverage": 0.8, "samples": 257},
]


class BrowserCurvePortTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.exe = detect_exe()
        cls.node = shutil.which("node")
        if not cls.exe:
            raise unittest.SkipTest("no built HyperDR curve command")
        if not cls.node:
            raise unittest.SkipTest("Node is required for the browser curve port test")

    def browser_curves(self, cases: list[dict] = CASES) -> list[list[float]]:
        runner = REPO_ROOT / "tests" / "js" / "curve_math_runner.mjs"
        completed = subprocess.run(
            [self.node, str(runner)],
            input=json.dumps(cases),
            text=True,
            capture_output=True,
            timeout=30,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        return json.loads(completed.stdout)

    def cpp_curve(self, case: dict) -> list[float]:
        options = {
            "contrast": case["contrast"],
            "hdrRange": case["hdrRange"],
            "expansionStart": case["expansionStart"],
            # Must not affect the one-dimensional global curve.
            "areaCoverage": case["areaCoverage"],
        }
        completed = subprocess.run(
            build_curve_argv(self.exe, options, case["samples"]),
            capture_output=True,
            timeout=30,
        )
        self.assertEqual(
            completed.returncode, 0, completed.stderr.decode(errors="replace"))
        return json.loads(completed.stdout.decode("utf-8"))["gain_stops"]

    def test_all_257_samples_match_cpp(self):
        for case, browser in zip(CASES, self.browser_curves(), strict=True):
            with self.subTest(case=case):
                reference = self.cpp_curve(case)
                self.assertEqual(len(browser), len(reference))
                maximum_error = max(
                    abs(actual - expected)
                    for actual, expected in zip(browser, reference, strict=True)
                )
                # C++ evaluates in float; JS evaluates in double and rounds each
                # stored sample to Float32. The observed error is ~1.2e-5 at the
                # held-white endpoint, so keep a small platform margin.
                self.assertLessEqual(maximum_error, 2e-5)

    def test_area_coverage_is_not_part_of_the_global_lut(self):
        base = dict(CASES[0])
        alternate = dict(base, areaCoverage=0.0)
        first, second = self.browser_curves([base, alternate])
        self.assertEqual(first, second)


if __name__ == "__main__":
    unittest.main()
