#!/usr/bin/env python3
"""Check that each panel's markup and its modules agree on every `data-role`.

The front-ends have no build step and no framework, so nothing checks that
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

#: The tree's markup is checked against its own modules. The dynamic roles
#: are the containers `settings/controls.js` fills from GROUP_CONTAINERS,
#: looked up via a variable rather than a literal.
TREES = [
    (
        REPO_ROOT / "apps" / "panel" / "web",
        {"group-tone", "group-region", "group-quality", "group-advanced"},
    ),
]

DECLARED_RE = re.compile(r'data-role="([^"]+)"')
USED_RE = re.compile(r'\brole(?:All)?\(\s*"([^"]+)"')


def check_tree(root: Path, dynamic_roles: set[str]) -> list[str]:
    problems: list[str] = []
    markup = root / "index.html"
    if not markup.is_file():
        return [f"missing {markup}"]

    declared = set(DECLARED_RE.findall(markup.read_text(encoding="utf-8")))

    used: dict[str, set[str]] = {}
    modules = sorted((root / "js").rglob("*.js"))
    if not modules:
        return [f"no front-end modules found under {root / 'js'}"]
    for module in modules:
        for name in USED_RE.findall(module.read_text(encoding="utf-8")):
            used.setdefault(name, set()).add(str(module.relative_to(REPO_ROOT)))

    missing = {name: sources for name, sources in used.items() if name not in declared}
    unused = declared - set(used) - dynamic_roles

    label = root.relative_to(REPO_ROOT)
    for name, sources in sorted(missing.items()):
        problems.append(f"[{label}] missing from index.html: data-role={name!r} "
                        f"(read by {', '.join(sorted(sources))})")
    for name in sorted(unused):
        problems.append(f"[{label}] declared but never read: data-role={name!r}")
    if not problems:
        print(f"[{label}] {len(declared)} roles declared, {len(used)} read, all matched")
    return problems


def main() -> int:
    problems: list[str] = []
    for root, dynamic_roles in TREES:
        problems.extend(check_tree(root, dynamic_roles))
    for problem in problems:
        print(problem, file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main())
