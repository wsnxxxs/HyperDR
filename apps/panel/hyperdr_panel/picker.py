"""Native file/folder pickers.

tkinter is spawned as a separate process (the launcher re-invoked with --pick)
so it always owns its own main thread; the HTTP handler runs in worker threads
where creating a Tk root is unsafe on some platforms. Manual path entry in the
browser is always available as a fallback.
"""
from __future__ import annotations

import subprocess
import sys

from .config import LAUNCHER


def run_picker(kind: str) -> int:
    """Show a native dialog and print the chosen path to stdout. Returns exit code."""
    try:
        import tkinter as tk
        from tkinter import filedialog
    except Exception as exc:  # tkinter missing
        sys.stderr.write("tkinter unavailable: %s" % exc)
        return 2
    root = tk.Tk()
    root.withdraw()
    try:
        root.attributes("-topmost", True)
    except Exception:
        pass
    if kind == "folder":
        path = filedialog.askdirectory(title="Select a folder")
    elif kind == "exe":
        path = filedialog.askopenfilename(
            title="Locate HyperDR executable",
            filetypes=[("HyperDR", "HyperDR*"), ("All files", "*.*")],
        )
    else:
        path = filedialog.askopenfilename(
            title="Select an input image",
            filetypes=[
                ("Supported images", "*.ARW *.arw *.DNG *.dng *.JPG *.jpg *.JPEG *.jpeg *.PNG *.png *.HEIC *.heic *.HEIF *.heif"),
                ("All files", "*.*"),
            ],
        )
    sys.stdout.write(path or "")
    root.destroy()
    return 0


def pick_via_subprocess(kind: str) -> tuple[str, str]:
    """Return (path, error). Runs the launcher in --pick mode."""
    try:
        result = subprocess.run(
            [sys.executable, str(LAUNCHER), "--pick", kind],
            capture_output=True, text=True, timeout=300,
        )
    except Exception as exc:
        return "", str(exc)
    if result.returncode != 0:
        return "", (result.stderr or "picker failed").strip()
    return result.stdout.strip(), ""
