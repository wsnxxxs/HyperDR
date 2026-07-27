"""Entry-point dispatch.

Keeping the picker branch here means the --pick subprocess only imports tkinter,
never the HTTP server, so it stays fast and side-effect free.
"""
from __future__ import annotations

import sys


def main(argv: list[str] | None = None) -> None:
    argv = list(sys.argv if argv is None else argv)
    if len(argv) >= 3 and argv[1] == "--pick":
        from .picker import run_picker
        raise SystemExit(run_picker(argv[2]))
    from .server import serve
    serve()
