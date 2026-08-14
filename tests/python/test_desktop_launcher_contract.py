"""Contracts shared by the Tauri desktop shell and the Python sidecar."""
from __future__ import annotations

import unittest
from pathlib import Path
from unittest import mock

from apps.panel.hyperdr_panel import app, server


ROOT = Path(__file__).resolve().parents[2]
APP = (ROOT / "apps" / "panel" / "hyperdr_panel" / "app.py").read_text(
    encoding="utf-8")
SERVER = (ROOT / "apps" / "panel" / "hyperdr_panel" / "server.py").read_text(
    encoding="utf-8")


class DesktopLauncherContractTests(unittest.TestCase):
    def test_launcher_dispatches_desktop_mode(self):
        self.assertIn('argv[1] == "--desktop"', APP)
        with mock.patch.object(server, "serve") as serve:
            app.main(["hyperdr_gui.py", "--desktop"])
        serve.assert_called_once_with(desktop=True)

    def test_server_announces_ready_url_without_opening_browser(self):
        self.assertIn("HYPERDR_READY", SERVER)
        self.assertIn("if not desktop and", SERVER)


if __name__ == "__main__":
    unittest.main()
