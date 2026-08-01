"""Shared paths and platform flags for the control panel."""
from __future__ import annotations

import os
from pathlib import Path

IS_WINDOWS = os.name == "nt"

# hyperdr_panel/ -> panel/ -> apps/ -> <repo root>
PACKAGE_DIR = Path(__file__).resolve().parent
GUI_DIR = PACKAGE_DIR.parent
REPO_ROOT = GUI_DIR.parent.parent

# The launcher is re-invoked in a subprocess for the native file picker so that
# tkinter always owns its own main thread.
LAUNCHER = GUI_DIR / "hyperdr_gui.py"

# Web root: a single source of truth for the front-end, also openable directly
# (double-click web/index.html) for an offline look at the interface, which is
# why its pages reference assets relatively and the CSP forbids `<base>`.
WEB_ROOT = GUI_DIR / "web"

PREFERRED_PORT = 8756
