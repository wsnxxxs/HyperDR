#!/usr/bin/env python3
"""Check the macOS app's String Catalog against the Swift that reads it.

The app uses semantic keys (`editor.open`, `err.server.raw_budget`,
`mac.display.edr %@ %@`) rather than English source text, so a key missing from
`Localizable.xcstrings` is not a build error: SwiftUI just shows the key. This
script is the guard, the native counterpart of check_panel_i18n.py:

* every key the app's Swift uses exists in the catalogue;
* every catalogue key is used (no dead entries);
* every entry has a translated, non-empty `en` and `zh-Hans` value, and both
  values take as many arguments as the key has `%@` placeholders;
* no string literal under `Views/` contains Chinese: user-visible text goes
  through the catalogue. Only `Views/` is held to this; the engine diagnostics
  window (`Shared/AppContentView.swift`) is a developer tool and is
  deliberately left unlocalized.

A key is any string literal whose first dot-separated segment is a namespace
the catalogue already uses (`editor`, `mac`, ...), which keeps SF Symbol names
like "arrow.uturn.backward" out. Interpolations become `%@`, which is what
Swift generates for a `String` argument. Views therefore interpolate only
`String`s into localized text: format numbers first, then interpolate.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
APP = REPO_ROOT / "apps" / "apple" / "HyperDR"
VIEWS = APP / "Views"
CATALOG = APP / "Resources" / "Localizable.xcstrings"
LOCALES = ["en", "zh-Hans"]

KEY_RE = re.compile(r"^([a-z][A-Za-z0-9]*)(?:\.[A-Za-z0-9_-]+)+(?: %@)*$")
CJK_RE = re.compile(r"[　-〿㐀-鿿＀-￯]")
# %@, %lld, %1$@ ... ; "%%" is a literal percent sign.
SPECIFIER_RE = re.compile(r"%(?:\d+\$)?(?:@|l{0,2}[dfu]|\.\d+f)")


def literals(source: str) -> list[tuple[int, str]]:
    """(line, text) for every string literal outside comments.

    Interpolations are replaced by `%@`; string literals nested inside an
    interpolation are returned as literals of their own.
    """
    found: list[tuple[int, str]] = []
    i, line, n = 0, 1, len(source)

    def read_string(start: int, line: int, multiline: bool) -> tuple[int, int]:
        """Read from just after the opening quote; return (index after the
        closing quote, line)."""
        quote = '"""' if multiline else '"'
        j = start
        text: list[str] = []
        begin = line
        while j < n:
            if source.startswith(quote, j):
                found.append((begin, "".join(text)))
                return j + len(quote), line
            ch = source[j]
            if ch == "\\" and j + 1 < n and source[j + 1] == "(":
                j, line = skip_interpolation(j + 2, line)
                text.append("%@")
                continue
            if ch == "\\":
                text.append(source[j:j + 2])
                j += 2
                continue
            if ch == "\n":
                line += 1
            text.append(ch)
            j += 1
        return j, line

    def skip_interpolation(j: int, line: int) -> tuple[int, int]:
        depth = 1
        while j < n and depth:
            if source.startswith('"""', j):
                j, line = read_string(j + 3, line, True)
                continue
            ch = source[j]
            if ch == '"':
                j, line = read_string(j + 1, line, False)
                continue
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
            elif ch == "\n":
                line += 1
            j += 1
        return j, line

    while i < n:
        if source.startswith("//", i):
            end = source.find("\n", i)
            i = n if end < 0 else end
        elif source.startswith("/*", i):
            end = source.find("*/", i + 2)
            end = n if end < 0 else end + 2
            line += source.count("\n", i, end)
            i = end
        elif source.startswith('"""', i):
            i, line = read_string(i + 3, line, True)
        elif source[i] == '"':
            i, line = read_string(i + 1, line, False)
        else:
            if source[i] == "\n":
                line += 1
            i += 1
    return found


def main() -> int:
    problems: list[str] = []
    try:
        catalog = json.loads(CATALOG.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        print(f"cannot read {CATALOG.relative_to(REPO_ROOT)}: {error}")
        return 1
    if catalog.get("sourceLanguage") != "en":
        problems.append("catalogue sourceLanguage must be 'en'")
    entries: dict = catalog.get("strings", {})
    namespaces = {m.group(1) for key in entries if (m := KEY_RE.match(key))}

    for key, entry in sorted(entries.items()):
        if not KEY_RE.match(key):
            problems.append(f"catalogue key is not a semantic key: {key!r}")
        expected = key.count("%@")
        for locale in LOCALES:
            unit = entry.get("localizations", {}).get(locale, {}).get("stringUnit", {})
            value = unit.get("value", "")
            if not value or unit.get("state") != "translated":
                problems.append(f"[{locale}] missing or untranslated: {key!r}")
                continue
            if len(SPECIFIER_RE.findall(value)) != expected:
                problems.append(f"[{locale}] {key!r} takes {expected} argument(s): {value!r}")

    used: dict[str, str] = {}
    for path in sorted(APP.rglob("*.swift")):
        relative = path.relative_to(REPO_ROOT)
        in_views = VIEWS in path.parents
        for line, text in literals(path.read_text(encoding="utf-8")):
            match = KEY_RE.match(text)
            if match and match.group(1) in namespaces:
                used.setdefault(text, f"{relative}:{line}")
            if in_views and CJK_RE.search(text):
                problems.append(f"{relative}:{line}: Chinese literal in Views/, use a catalogue key: {text!r}")

    for key, where in sorted(used.items()):
        if key not in entries:
            problems.append(f"{where}: key not in catalogue: {key!r}")
    for key in sorted(set(entries) - set(used)):
        problems.append(f"unused catalogue key: {key!r}")

    for problem in problems:
        print(problem)
    if problems:
        print(f"\n{len(problems)} problem(s)")
        return 1
    print(f"ok: {len(entries)} keys, {len(LOCALES)} locales")
    return 0


if __name__ == "__main__":
    sys.exit(main())
