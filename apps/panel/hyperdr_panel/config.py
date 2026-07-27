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
# (double-click static/index.html) for an offline look at the interface.
STATIC_DIR = GUI_DIR / "static"

# The rewritten front-end, served at /next while it is built beside the panel
# above rather than on top of it. Two roots in one process is what lets the
# rewrite be compared against the interface it replaces at every step, and what
# keeps a half-finished /next from blocking a release. At cutover this becomes
# the only root and STATIC_DIR goes away in a single commit.
WEB_DIR = GUI_DIR / "web"
WEB_ROUTE_PREFIX = "/next"

PREFERRED_PORT = 8756
