#!/usr/bin/env python3
"""Check that the panel's string catalogues agree with each other and the code.

The front-end has no build step, so nothing catches a typo'd translation key:
`t("run.strat")` is valid JavaScript that renders the key itself, and a key
present in zh-CN.js but missing from en.js silently falls back to Chinese in an
English UI. Neither is a parse error, so neither shows up in CI without this.

Keys assembled from a variable -- `ctrl.<control>.label`, `enc.<id>.hint`,
`err.server.<code>`, `prefs.<pref>.<field>` -- cannot be found by reading the
source, so their prefixes are listed as dynamic families instead of being
reported as dead entries.

This is the i18n counterpart to check_panel_roles.py and runs beside it.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
WEB = REPO_ROOT / "apps" / "panel" / "web"
I18N = WEB / "js" / "i18n"

#: zh-CN is the source catalogue; every other locale is checked against it.
SOURCE_LOCALE = "zh-CN"
LOCALES = ["zh-CN", "en"]

#: Key families built by string concatenation rather than written out. A key
#: under one of these prefixes is never reported as unused; the module that
#: assembles it is named so the pairing can be re-checked by hand.
DYNAMIC_PREFIXES = {
    "ctrl.": "js/settings/schema.js builds ctrl.<key>.label / .help",
    "enc.": "js/settings/schema.js builds enc.<id>.hint",
    "err.server.": "js/core/api.js maps a server `code` to err.server.<code>",
    "prefs.": "js/ui/prefs.js builds prefs.<key>.label / .help / .<choice>",
    "scope.": "js/preview/scope.js builds scope.<mode> for the histogram modes",
    "stage.input.": "js/preview/stage.js builds stage.input.<domain>",
    "hdr.reason.": "js/preview/stage.js passes hdr.reason.<why> into a template",
}

# "key": "value" -- one entry per line, which is how the catalogues are written.
ENTRY_RE = re.compile(r'^\s*"([^"]+)"\s*:', re.MULTILINE)
# t("key") / t("key", {...}). The word boundary keeps `.at("x")` and friends out.
USED_RE = re.compile(r'(?<![\w.])t\(\s*"([^"]+)"')
# Keys also travel as plain data -- settings/schema.js stores them in `label`,
# `help` and `choices` instead of calling t() at the declaration site. Any
# string literal whose first segment is a catalogue namespace is treated as a
# key reference, so a typo there fails the build too. Deriving the namespaces
# from the catalogue is what keeps this from matching "hyperdr.settings.v2".
LITERAL_RE = re.compile(r'"([a-z][A-Za-z0-9]*(?:\.[A-Za-z0-9_-]+)+)"')
MARKUP_RE = re.compile(r'data-i18n="([^"]+)"')
MARKUP_ATTR_RE = re.compile(r'data-i18n-attr="([^"]+)"')


def catalogue_keys(locale: str) -> tuple[list[str], list[str]]:
    """Return (keys, problems) for one locale file."""
    path = I18N / f"{locale}.js"
    if not path.is_file():
        return [], [f"missing catalogue {path.relative_to(REPO_ROOT)}"]
    keys = ENTRY_RE.findall(path.read_text(encoding="utf-8"))
    problems = []
    duplicates = {key for key in keys if keys.count(key) > 1}
    for key in sorted(duplicates):
        problems.append(f"[{locale}] duplicate key: {key!r}")
    return keys, problems


def is_dynamic(key: str) -> bool:
    return any(key.startswith(prefix) for prefix in DYNAMIC_PREFIXES)


def main() -> int:
    problems: list[str] = []

    catalogues: dict[str, list[str]] = {}
    for locale in LOCALES:
        keys, issues = catalogue_keys(locale)
        catalogues[locale] = keys
        problems.extend(issues)
    if problems:
        for problem in problems:
            print(problem, file=sys.stderr)
        return 1

    # 1. Every locale carries exactly the source locale's keys.
    source = set(catalogues[SOURCE_LOCALE])
    for locale in LOCALES:
        if locale == SOURCE_LOCALE:
            continue
        keys = set(catalogues[locale])
        for key in sorted(source - keys):
            problems.append(f"[{locale}] missing key present in {SOURCE_LOCALE}: {key!r}")
        for key in sorted(keys - source):
            problems.append(f"[{locale}] key not in {SOURCE_LOCALE}: {key!r}")

    # 2. Every key the code asks for exists; every key declared is asked for.
    namespaces = {key.split(".", 1)[0] for key in source}
    used: dict[str, set[str]] = {}
    modules = sorted((WEB / "js").rglob("*.js"))
    if not modules:
        problems.append(f"no front-end modules found under {WEB / 'js'}")
    for module in modules:
        if module.parent == I18N:
            continue  # the catalogues declare keys, they do not consume them
        text = module.read_text(encoding="utf-8")
        source_name = str(module.relative_to(REPO_ROOT))
        for key in USED_RE.findall(text):
            used.setdefault(key, set()).add(source_name)
        for key in LITERAL_RE.findall(text):
            if key.split(".", 1)[0] in namespaces:
                used.setdefault(key, set()).add(source_name)

    markup = WEB / "index.html"
    if markup.is_file():
        text = markup.read_text(encoding="utf-8")
        for key in MARKUP_RE.findall(text):
            used.setdefault(key, set()).add("index.html")
        for spec in MARKUP_ATTR_RE.findall(text):
            for pair in spec.split(";"):
                _, _, key = pair.partition(":")
                if key.strip():
                    used.setdefault(key.strip(), set()).add("index.html")

    for key, sources in sorted(used.items()):
        if key not in source:
            problems.append(f"[{SOURCE_LOCALE}] key asked for but never declared: "
                            f"{key!r} (read by {', '.join(sorted(sources))})")

    for key in sorted(source - set(used)):
        if is_dynamic(key):
            continue
        problems.append(f"[{SOURCE_LOCALE}] declared but never read: {key!r}")

    for problem in problems:
        print(problem, file=sys.stderr)
    if not problems:
        print(f"[apps/panel/web] {len(source)} keys x {len(LOCALES)} locales, "
              f"{len(used)} read, all matched")
    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main())
