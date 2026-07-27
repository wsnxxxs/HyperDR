"""Locating the converter.

The panel only ever runs the real HyperDR executable: it never reimplements a
conversion, and never guesses at what one would have produced.
"""
from __future__ import annotations

import os
import shutil
from pathlib import Path

from .config import IS_WINDOWS, REPO_ROOT

# Where a build lands, in the order a developer is most likely to want.
_SEARCH_SUBDIRECTORIES = (
    "bin",
    "build-codecs-win/Release",
    "build-codecs-win/modules/app/Release",
    "build-codecs-win/modules/app",
    "build-codecs-win",
    "build/modules/app",
    "build/modules/app/Release",
    "build/modules/app/Debug",
    "build",
    "build/Release",
    "build/Debug",
    "build-core/modules/app",
    "build-core/modules/app/Release",
    "build-core",
    "",
)


def detect_exe() -> str:
    """Find a built HyperDR executable in the usual locations or on PATH."""
    names = ["HyperDR.exe", "HyperDR"] if IS_WINDOWS else ["HyperDR"]
    configured = os.environ.get("HYPERDR_EXECUTABLE", "")
    if configured and Path(configured).is_file():
        return configured
    for subdirectory in _SEARCH_SUBDIRECTORIES:
        folder = REPO_ROOT / subdirectory if subdirectory else REPO_ROOT
        for name in names:
            candidate = folder / name
            if candidate.is_file():
                return str(candidate)
    for name in names:
        found = shutil.which(name)
        if found:
            return found
    return ""
