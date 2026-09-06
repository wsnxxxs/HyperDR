"""Start the local editor, optionally hosted by the desktop shell."""
from __future__ import annotations

import sys


def main(argv: list[str] | None = None) -> None:
    argv = list(sys.argv if argv is None else argv)
    if len(argv) >= 2 and argv[1] == "--desktop":
        from .server import serve
        serve(desktop=True)
        return
    from .server import serve
    serve()
