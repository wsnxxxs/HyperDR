"""Desktop mode dispatches to the panel sidecar."""
from unittest import TestCase, mock

from apps.panel.hyperdr_panel import app, server


class DesktopLauncherTests(TestCase):
    def test_launcher_dispatches_desktop_mode(self):
        with mock.patch.object(server, "serve") as serve:
            app.main(["hyperdr_gui.py", "--desktop"])
        serve.assert_called_once_with(desktop=True)
