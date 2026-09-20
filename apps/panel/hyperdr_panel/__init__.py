"""hyperdr control panel — a local web UI.

The basic panel uses the standard library. Phone certificate generation adds
cryptography, bundled in desktop releases. Entry point: :func:`main`.
"""
from __future__ import annotations

from .app import main

__all__ = ["main"]
