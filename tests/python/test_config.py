from __future__ import annotations

import unittest

from apps.panel.hyperdr_panel.config import WEB_ROOT


class PanelConfigTests(unittest.TestCase):
    def test_source_checkout_web_root_contains_panel_entrypoint(self):
        self.assertTrue((WEB_ROOT / "index.html").is_file())


if __name__ == "__main__":
    unittest.main()
