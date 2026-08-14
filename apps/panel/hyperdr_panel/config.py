"""Shared paths and platform flags for the control panel."""
from __future__ import annotations

import os
from pathlib import Path
import sys

IS_WINDOWS = os.name == "nt"
IS_FROZEN = bool(getattr(sys, "frozen", False))

# hyperdr_panel/ -> panel/ -> apps/ -> <repo root>
PACKAGE_DIR = Path(__file__).resolve().parent
GUI_DIR = PACKAGE_DIR.parent


def _frozen_resource_root() -> Path:
    """Find the read-only resource root used by a PyInstaller sidecar."""
    meipass = Path(getattr(sys, "_MEIPASS", GUI_DIR))
    candidates = (GUI_DIR, meipass, meipass / "_internal")
    for candidate in candidates:
        if (candidate / "web" / "index.html").is_file():
            return candidate.resolve()
    # Keep the failure useful: the caller will report the missing web root
    # instead of silently serving the source tree from an unexpected location.
    return GUI_DIR.resolve()


RESOURCE_ROOT = _frozen_resource_root() if IS_FROZEN else GUI_DIR.parent.parent
REPO_ROOT = RESOURCE_ROOT

# The launcher is re-invoked in a subprocess for the native file picker so that
# tkinter always owns its own main thread.
LAUNCHER = Path(sys.executable) if IS_FROZEN else GUI_DIR / "hyperdr_gui.py"

# Web root: a single source of truth for the front-end, also openable directly
# (double-click web/index.html) for an offline look at the interface, which is
# why its pages reference assets relatively and the CSP forbids `<base>`.
WEB_ROOT = RESOURCE_ROOT / "web"

PREFERRED_PORT = 8756
