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
TAURI = (ROOT / "apps" / "desktop" / "src-tauri" / "src" / "lib.rs").read_text(
    encoding="utf-8")
PROCESS_TREE = (ROOT / "apps" / "desktop" / "src-tauri" / "src" / "process_tree.rs").read_text(
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

    def test_windows_webview_is_configured_for_display_p3_webgpu(self):
        self.assertIn("--enable-features=WebGPU,UseDisplayP3ColorSpace", TAURI)
        self.assertIn("additional_browser_args", TAURI)

    def test_sidecar_termination_owns_the_whole_process_tree(self):
        self.assertIn("JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE", PROCESS_TREE)
        self.assertIn('command.args(["/PID", &pid, "/T", "/F"])', PROCESS_TREE)

    def test_native_drop_is_forwarded_to_the_panel(self):
        self.assertIn("DragDropEvent::Drop", TAURI)
        self.assertIn("NativeDropQueue", TAURI)
        self.assertIn("PageLoadEvent::Finished", TAURI)
        self.assertIn("on_page_load", TAURI)
        self.assertIn("hyperdr:native-file-drop", TAURI)


if __name__ == "__main__":
    unittest.main()
