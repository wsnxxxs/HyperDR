#!/usr/bin/env python3
"""Check that the panel's markup and its modules agree on every `data-role`.

The front-end has no build step and no framework, so nothing checks that
`role("run")` in a module corresponds to a `data-role="run"` in the markup. A
mismatch is not a parse error: the lookup simply returns null and the panel
fails at the first click, which a syntax check cannot see. This closes that gap
cheaply enough to run on every push.

Roles that are looked up through a variable -- the settings groups, which come
from a table in `controls.js` -- cannot be found by reading the source, so they
are listed here explicitly rather than reported as dead markup.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
STATIC = REPO_ROOT / "apps" / "panel" / "static"

#: Looked up via `GROUP_CONTAINERS` in settings/controls.js, not by literal.
DYNAMIC_ROLES = {"group-tone", "group-region", "group-quality", "group-advanced"}

DECLARED_RE = re.compile(r'data-role="([^"]+)"')
USED_RE = re.compile(r'\brole(?:All)?\(\s*"([^"]+)"')


def main() -> int:
    markup = STATIC / "index.html"
    if not markup.is_file():
        print(f"missing {markup}", file=sys.stderr)
        return 1

    declared = set(DECLARED_RE.findall(markup.read_text(encoding="utf-8")))

    used: dict[str, set[str]] = {}
    modules = sorted((STATIC / "js").rglob("*.js"))
    if not modules:
        print("no front-end modules found", file=sys.stderr)
        return 1
    for module in modules:
        for name in USED_RE.findall(module.read_text(encoding="utf-8")):
            used.setdefault(name, set()).add(str(module.relative_to(REPO_ROOT)))

    missing = {name: sources for name, sources in used.items() if name not in declared}
    unused = declared - set(used) - DYNAMIC_ROLES

    for name, sources in sorted(missing.items()):
        print(f"missing from index.html: data-role={name!r} "
              f"(read by {', '.join(sorted(sources))})", file=sys.stderr)
    for name in sorted(unused):
        print(f"declared but never read: data-role={name!r}", file=sys.stderr)

    if missing or unused:
        return 1
    print(f"{len(declared)} roles declared, {len(used)} read, all matched")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
