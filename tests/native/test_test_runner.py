"""The test runner offers only the product suites."""
import contextlib
import importlib.util
import io
from pathlib import Path
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("hyperdr_test_runner", ROOT / "scripts/test.py")
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class TestRunnerTest(unittest.TestCase):
    def test_all_runs_the_native_suite_only(self):
        with patch("sys.argv", ["test.py", "all"]), patch.object(runner, "native") as native, \
                patch.object(runner, "apple") as apple:
            self.assertEqual(runner.main(), 0)
        native.assert_called_once()
        apple.assert_not_called()

    def test_the_retired_panel_and_frontend_suites_are_gone(self):
        for suite in ("panel", "frontend"):
            with self.subTest(suite=suite), patch("sys.argv", ["test.py", suite]), \
                    contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                runner.main()
