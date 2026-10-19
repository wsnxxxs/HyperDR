"""The retired reference panel must never run as part of product validation."""
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
    def test_all_runs_product_suites_without_the_retired_panel(self):
        with patch("sys.argv", ["test.py", "all"]), patch.object(runner, "panel") as panel, \
                patch.object(runner, "frontend") as frontend, patch.object(runner, "native") as native:
            self.assertEqual(runner.main(), 0)
        panel.assert_not_called()
        frontend.assert_called_once_with()
        native.assert_called_once()

    def test_panel_explicitly_reports_retirement_and_fails(self):
        stderr = io.StringIO()
        with patch("sys.argv", ["test.py", "panel"]), \
                patch.object(runner, "run") as run, contextlib.redirect_stderr(stderr):
            self.assertEqual(runner.main(), 1)
        run.assert_not_called()
        self.assertIn("已退役，P2c 删除", stderr.getvalue())
