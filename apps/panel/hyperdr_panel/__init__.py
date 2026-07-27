"""hyperdr control panel — a local, standard-library-only web UI.

The package is intentionally small and dependency-free so it runs on the
official Windows Python without any pip installs. Entry point: :func:`main`.
"""
from __future__ import annotations

from .app import main

__all__ = ["main"]
