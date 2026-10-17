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
* a semantic key passed as `verbatim:` is an error: it would show the key
  itself, and it does not count as a use of the entry;
* no string literal under `Views/` contains Chinese: user-visible text goes
  through the catalogue. Only `Views/` is held to this; the engine diagnostics
  window (`Shared/AppContentView.swift`) is a developer tool and is
  deliberately left unlocalized.

Which literals are keys:

* A literal in an explicitly localized position -- the first argument of
  `Text(`, `Button(`, `Label(`, `String(localized:`, `LocalizedStringKey(`,
  `LocalizedStringResource(`, `.help(` and the like -- is a key whatever its
  namespace, so a key in a namespace the catalogue does not have yet is still
  checked.
* Elsewhere (a view's own `LocalizedStringKey` parameter, a ternary, a
  `switch` returning keys) a literal is a key when its first dot-separated
  segment is a namespace the catalogue already uses. A brand-new namespace
  in such a position is not seen until one of its keys is in the catalogue
  or in an explicit position.
* Arguments that name things rather than text -- `systemImage:`,
  `systemName:`, `id:`, `forKey:` and similar -- are never keys, which keeps
  SF Symbol names like "arrow.uturn.backward" out.

Interpolations become `%@`, which is what Swift generates for a `String`
argument. Views therefore interpolate only `String`s into localized text:
format numbers first, then interpolate.

`--self-test` (also run before every check) applies mutations to the real
sources in memory -- a missing key in a new namespace, a key in `verbatim:`,
an SF Symbol in an explicit position -- and fails unless each is reported
(or, for the symbol, not reported).
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


def literals(source: str) -> list[tuple[int, int, str]]:
    """(line, offset of the opening quote, text) for every string literal
    outside comments.

    Interpolations are replaced by `%@`; string literals nested inside an
    interpolation are returned as literals of their own.
    """
    found: list[tuple[int, int, str]] = []
    i, line, n = 0, 1, len(source)

    def read_string(start: int, line: int, multiline: bool) -> tuple[int, int]:
        """Read from just after the opening quote; return (index after the
        closing quote, line)."""
        quote = '"""' if multiline else '"'
        opening = start - len(quote)
        j = start
        text: list[str] = []
        begin = line
        while j < n:
            if source.startswith(quote, j):
                found.append((begin, opening, "".join(text)))
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


# The literal is the first argument of a call that localizes it.
LOCALIZED_CONTEXT = re.compile(
    r"(?:\b(?:Text|Button|Label|Toggle|Picker|Menu|Section|SectionHeading|Window|WindowGroup"
    r"|CommandMenu|LocalizedStringKey|LocalizedStringResource)\s*\("
    r"|\bString\s*\(\s*localized\s*:"
    r"|\.(?:help|accessibilityLabel|accessibilityHint|accessibilityValue|navigationTitle"
    r"|navigationSubtitle|alert|confirmationDialog)\s*\()\s*$"
)
# The literal names a symbol, scene, defaults key or file, not text.
NOT_TEXT_CONTEXT = re.compile(
    r"\b(?:systemImage|systemName|id|forKey|named|subsystem|category|identifier"
    r"|fileURLWithPath|forResource|withExtension)\s*:\s*$"
)
VERBATIM_CONTEXT = re.compile(r"\bverbatim\s*:\s*$")
CONTEXT_CHARS = 120


def check(files: list[tuple[str, bool, str]], entries: dict) -> list[str]:
    """Problems for `files` -- (path for messages, under Views/, source) --
    against the catalogue's `entries`."""
    problems: list[str] = []
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
    for relative, in_views, source in files:
        for line, offset, text in literals(source):
            where = f"{relative}:{line}"
            if in_views and CJK_RE.search(text):
                problems.append(f"{where}: Chinese literal in Views/, use a catalogue key: {text!r}")
            match = KEY_RE.match(text)
            if not match:
                continue
            context = source[max(0, offset - CONTEXT_CHARS):offset]
            if VERBATIM_CONTEXT.search(context):
                if text in entries or match.group(1) in namespaces:
                    problems.append(f"{where}: semantic key shown verbatim, drop `verbatim:`: {text!r}")
                continue
            if NOT_TEXT_CONTEXT.search(context):
                continue
            if LOCALIZED_CONTEXT.search(context) or match.group(1) in namespaces:
                used.setdefault(text, where)

    for key, where in sorted(used.items()):
        if key not in entries:
            problems.append(f"{where}: key not in catalogue: {key!r}")
    for key in sorted(set(entries) - set(used)):
        problems.append(f"unused catalogue key: {key!r}")
    return problems


def self_test(files: list[tuple[str, bool, str]], entries: dict) -> list[str]:
    """Failures of the mutation self-test: each mutation is added to the real
    sources (and, where needed, the catalogue) and must change the report as
    expected."""
    baseline = set(check(files, entries))
    used_key = next(key for key in sorted(entries) if "%@" not in key)
    namespace = used_key.split(".")[0]
    probe = dict(entries[used_key])
    view = "apps/apple/HyperDR/Views/SelfTest.swift"
    # (name, source added under Views/, extra catalogue keys,
    #  fragments some new problem must contain, or None for "no new problem")
    mutations = [
        ("Text with a key in a new namespace",
         'Text("zzselftest.text")', [], ["key not in catalogue", "'zzselftest.text'"]),
        ("String(localized:) with a key in a new namespace",
         'String(localized: "zzselftest.string")', [], ["key not in catalogue", "'zzselftest.string'"]),
        ("LocalizedStringResource with a key in a new namespace",
         'LocalizedStringResource("zzselftest.resource")', [], ["key not in catalogue", "'zzselftest.resource'"]),
        (".help with a key in a new namespace",
         '.help("zzselftest.help")', [], ["key not in catalogue", "'zzselftest.help'"]),
        ("a used key shown verbatim",
         f'Text(verbatim: "{used_key}")', [], ["shown verbatim", repr(used_key)]),
        ("a verbatim key does not count as used",
         'Text(verbatim: "zzselftest.only")', ["zzselftest.only"], ["unused catalogue key: 'zzselftest.only'"]),
        # Symbols in a catalogue namespace, as "app.badge" is in "app".
        ("SF Symbols are not keys",
         f'Label("{used_key}", systemImage: "{namespace}.zzselftest.fill"); '
         f'Image(systemName: "{namespace}.zzselftest")', [], None),
    ]
    failures: list[str] = []
    for name, source, extra, expected in mutations:
        catalogue = dict(entries)
        for key in extra:
            catalogue[key] = probe
        found = set(check([*files, (view, True, source + "\n")], catalogue)) - baseline
        if expected is None:
            if found:
                failures.append(f"self-test: {name}: unexpected {sorted(found)}")
        elif not any(all(fragment in problem for fragment in expected) for problem in found):
            failures.append(f"self-test: {name}: not reported (got {sorted(found)})")
    return failures


def main() -> int:
    try:
        catalog = json.loads(CATALOG.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        print(f"cannot read {CATALOG.relative_to(REPO_ROOT)}: {error}")
        return 1
    entries: dict = catalog.get("strings", {})
    files = [
        (str(path.relative_to(REPO_ROOT)), VIEWS in path.parents, path.read_text(encoding="utf-8"))
        for path in sorted(APP.rglob("*.swift"))
    ]

    problems = self_test(files, entries)
    if "--self-test" not in sys.argv[1:]:
        if catalog.get("sourceLanguage") != "en":
            problems.append("catalogue sourceLanguage must be 'en'")
        problems += check(files, entries)

    for problem in problems:
        print(problem)
    if problems:
        print(f"\n{len(problems)} problem(s)")
        return 1
    if "--self-test" in sys.argv[1:]:
        print("ok: self-test")
    else:
        print(f"ok: {len(entries)} keys, {len(LOCALES)} locales (self-test passed)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
