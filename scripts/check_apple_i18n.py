#!/usr/bin/env python3
"""Check the macOS app's String Catalog against the Swift that reads it.

The app uses semantic keys (`editor.open`, `err.server.raw_budget`,
`mac.display.edr %@ %@`) rather than English source text, so a key missing from
`Localizable.xcstrings` is not a build error: SwiftUI just shows the key. This
script is the guard:

* every key the app's Swift uses exists in the catalogue;
* every catalogue key is used (no dead entries), except the keys under
  `DYNAMIC_PREFIXES`;
* every entry has a translated, non-empty `en` and `zh-Hans` value, and both
  values take as many arguments as the key has `%@` placeholders;
* a semantic key passed as `verbatim:` is an error: it would show the key
  itself, and it does not count as a use of the entry;
* no string literal under `Views/` contains Chinese: user-visible text goes
  through the catalogue.
* nor in `Editor/`, `Frame/`, `macOS/` or `Shared/` (comments do not count):
  what those layers produce reaches the user as text too (§13 R5). Their
  diagnostics -- error details, the engine diagnostics window
  (`Shared/AppContentView.swift`) -- are in English and not translated.
  `CJK_OUTSIDE_VIEWS_STRICT = False` would turn this back into a warning.

Keys built at run time cannot be seen in the Swift: `ctrl.<key>.label` and
`.help` come from the controls table in HyperDRKit (`EditControls`),
`choice.<key>.<id>` from its options (`EditChoices`), and `field.<name>` from
the capture fields the engine reports as missing. Such a key is not reported
as unused; the other direction is the job of
`HyperDRPreviewTests/LocalizationCoverageTests.swift`, which lists the keys
from the tables and asserts each is in the catalogue in both languages, and
that no key under these prefixes lacks a control, option or field behind it.
A literal that uses one of them in a view still has to exist in the catalogue.

One rule here is not about strings but sits with them because it reads the
same sources: nothing under `Views/` imports `HyperDREngine`. Views talk only
to the editor models (batch 3 §3.4); engine types and calls stay in
`Editor/`, `Frame/` and the services, which hand views app-owned values.

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

The design package (`Packages/HyperDRDesign`) has a catalogue of its own for
the few strings its components say themselves (`design.*`: Reset to Default,
Expanded / Collapsed). Its sources are checked against it the same way, with
one more rule: a key there must be looked up with `bundle: .module`, or it
would be looked up in the app's catalogue and show as the key. Chinese
literals are an error in its `Inspector/` components; the token gallery shows
Chinese type specimens on purpose.

The HEIF reader names the feature it cannot read (`HeifReadError(message,
"feature")` in the engine sources). Each feature the sources can throw must be
in `ErrorText.heifFeatures` and have an
`err.server.unsupported_format.heif.<feature>` sentence in both languages, and
nothing in the list may be a feature the sources no longer throw.

`--self-test` (also run before every check) applies mutations to the real
sources in memory -- a missing key in a new namespace, a key in `verbatim:`,
an SF Symbol in an explicit position, an engine import in a view -- and fails unless each is reported
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
DESIGN = REPO_ROOT / "apps" / "apple" / "Packages" / "HyperDRDesign" / "Sources" / "HyperDRDesign"
DESIGN_CATALOG = DESIGN / "Resources" / "Localizable.xcstrings"
DESIGN_COMPONENTS = DESIGN / "Inspector"
LOCALES = ["en", "zh-Hans"]
# Every engine source (not the tests) that can throw HeifReadError with a feature.
HEIF_SOURCE_GLOBS = ("modules/*/src/**/*", "modules/*/include/**/*")
HEIF_SOURCE_SUFFIXES = {".cpp", ".cc", ".hpp", ".h", ".mm"}
HEIF_FEATURE_KEY = "err.server.unsupported_format.heif."
ERROR_TEXT = APP / "Views" / "ErrorText.swift"
# Keys read through a name built at run time (see the module docstring); never
# reported as unused. Their completeness is the Swift coverage test's.
DYNAMIC_PREFIXES = ("ctrl.", "choice.", "field.", "enc.", "export.stage.", "export.unavailable.")

KEY_RE = re.compile(r"^([a-z][A-Za-z0-9]*)(?:\.[A-Za-z0-9_-]+)+(?: %@)*$")
CJK_RE = re.compile(r"[　-〿㐀-鿿＀-￯]")
# Layers outside Views/ held to the no-Chinese rule, and whether it fails.
CJK_OUTSIDE_VIEWS = ("Editor", "Frame", "macOS", "Shared")
CJK_OUTSIDE_VIEWS_STRICT = True
# %@, %lld, %1$@ ... ; "%%" is a literal percent sign.
SPECIFIER_RE = re.compile(r"%(?:\d+\$)?(?:@|l{0,2}[dfu]|\.\d+f)")


RAW_QUOTE_RE = re.compile(r'(#*)("""|")')


def comment_end(source: str, j: int) -> int | None:
    """Just after the comment starting at `j` -- a line comment up to its
    newline, or a block comment with any nested in it, as Swift nests them --
    or None when none starts there."""
    if source.startswith("//", j):
        end = source.find("\n", j)
        return len(source) if end < 0 else end
    if source.startswith("/*", j):
        depth, end, n = 1, j + 2, len(source)
        while end < n and depth:
            if source.startswith("/*", end):
                depth, end = depth + 1, end + 2
            elif source.startswith("*/", end):
                depth, end = depth - 1, end + 2
            else:
                end += 1
        return end
    return None


def literals(source: str) -> list[tuple[int, int, str]]:
    """(line, offset of the opening delimiter, text) for every string literal
    outside comments, raw (`#"..."#`) and multi-line ones included.

    Interpolations are replaced by `%@`; string literals nested inside an
    interpolation are returned as literals of their own, and comments there
    are skipped as anywhere else.
    """
    found: list[tuple[int, int, str]] = []
    i, line, n = 0, 1, len(source)

    def read_string(opening: int, start: int, line: int, hashes: str, quote: str) -> tuple[int, int]:
        """Read from just after the opening delimiter; return (index after
        the closing one, line)."""
        close = quote + hashes
        escape = "\\" + hashes
        j = start
        text: list[str] = []
        begin = line
        while j < n:
            if source.startswith(close, j):
                found.append((begin, opening, "".join(text)))
                return j + len(close), line
            if source.startswith(escape + "(", j):
                j, line = skip_interpolation(j + len(escape) + 1, line)
                text.append("%@")
                continue
            if source.startswith(escape, j):
                text.append(source[j:j + len(escape) + 1])
                j += len(escape) + 1
                continue
            ch = source[j]
            if ch == "\n":
                line += 1
            text.append(ch)
            j += 1
        return j, line

    def skip_interpolation(j: int, line: int) -> tuple[int, int]:
        depth = 1
        while j < n and depth:
            end = comment_end(source, j)
            if end is not None:
                line += source.count("\n", j, end)
                j = end
                continue
            if match := RAW_QUOTE_RE.match(source, j):
                j, line = read_string(j, match.end(), line, match.group(1), match.group(2))
                continue
            ch = source[j]
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
            elif ch == "\n":
                line += 1
            j += 1
        return j, line

    while i < n:
        end = comment_end(source, i)
        if end is not None:
            line += source.count("\n", i, end)
            i = end
        elif match := RAW_QUOTE_RE.match(source, i):
            i, line = read_string(i, match.end(), line, match.group(1), match.group(2))
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
# A package key's call names the package bundle within this many characters.
MODULE_BUNDLE = re.compile(r"\bbundle\s*:\s*\.module\b")
BUNDLE_CHARS = 240


def check(files: list[tuple[str, bool, str]], entries: dict, module_bundle: bool = False) -> list[str]:
    """Problems for `files` -- (path for messages, held to the no-Chinese
    rule, source) -- against the catalogue's `entries`. `module_bundle`: the
    files are a package's, whose keys must be read with `bundle: .module`."""
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
                problems.append(f"{where}: Chinese literal, use a catalogue key: {text!r}")
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
                if module_bundle and not MODULE_BUNDLE.search(source, offset, offset + BUNDLE_CHARS):
                    problems.append(f"{where}: package key read without `bundle: .module`: {text!r}")

    for key, where in sorted(used.items()):
        if key not in entries:
            problems.append(f"{where}: key not in catalogue: {key!r}")
    for key in sorted(set(entries) - set(used)):
        if key.startswith(DYNAMIC_PREFIXES):
            continue
        problems.append(f"unused catalogue key: {key!r}")
    return problems


# An import of the engine in code (comments and strings already blanked):
# any attributes (`@testable`, `@_exported`, `@_spi(X)`, `@preconcurrency`)
# and access level (`internal import`, `public import` ...), on the same line
# or the lines before, then an optional kind (`import struct HyperDREngine.X`).
ENGINE_IMPORT_RE = re.compile(
    r"^[ \t]*(?:(?:@\w+(?:\([^()]*\))?|open|public|package|internal|fileprivate|private)\s+)*"
    r"(?P<keyword>import)\s+(?:(?:struct|class|enum|protocol|func|typealias|var|let)\s+)?"
    r"HyperDREngine\b", re.MULTILINE)


def code_only(source: str) -> str:
    """`source` with comments and string literals blanked to spaces, newlines
    kept, so a match's line number is still right. Handles nested block
    comments, multi-line and raw strings, and interpolations (code again,
    with strings of their own)."""
    out = list(source)
    n = len(source)

    def blank(start: int, end: int) -> None:
        for k in range(start, end):
            if out[k] != "\n":
                out[k] = " "

    def string_end(j: int, hashes: str, quote: str) -> int:
        """From just after the opening delimiter to just after the closing one."""
        close = quote + hashes
        escape = "\\" + hashes
        while j < n:
            if source.startswith(close, j):
                return j + len(close)
            if quote == '"' and source[j] == "\n":
                return j  # unterminated: stop at the line's end
            if source.startswith(escape + "(", j):
                j = code_end(j + len(escape) + 1)
                continue
            if source.startswith(escape, j):
                j += len(escape) + 1
                continue
            j += 1
        return n

    def code_end(j: int) -> int:
        """From just inside an interpolation's `(` to just after its `)`.
        The interpolation is code, so its comments and strings are skipped
        the same way as outside (a quote in a comment there opens nothing);
        all of it stays blanked with the string around it."""
        depth = 1
        while j < n and depth:
            end = token_end(j)
            if end is not None:
                j = end
                continue
            depth += {"(": 1, ")": -1}.get(source[j], 0)
            j += 1
        return j

    def token_end(j: int) -> int | None:
        """Just after the comment or string literal starting at `j`, or None
        when none starts there."""
        end = comment_end(source, j)
        if end is not None:
            return end
        if match := RAW_QUOTE_RE.match(source, j):
            return string_end(match.end(), match.group(1), match.group(2))
        return None

    i = 0
    while i < n:
        end = token_end(i)
        if end is None:
            i += 1
            continue
        blank(i, end)
        i = end
    return "".join(out)


def engine_imports(files: list[tuple[str, bool, str]]) -> list[str]:
    """Views that import the engine: `files` as for `check`, where the flag
    marks a file under `Views/`."""
    problems = []
    for relative, in_views, source in files:
        if not in_views:
            continue
        code = code_only(source)
        for match in ENGINE_IMPORT_RE.finditer(code):
            line = code.count("\n", 0, match.start("keyword")) + 1
            problems.append(f"{relative}:{line}: views must not import HyperDREngine; go through the editor model")
    return problems


def chinese_outside_views(files: list[tuple[str, bool, str]]) -> list[str]:
    """Chinese string literals in the app's layers outside `Views/`."""
    app = str(APP.relative_to(REPO_ROOT)) + "/"
    found = []
    for relative, _, source in files:
        layer = relative[len(app):].split("/")[0] if relative.startswith(app) else ""
        if layer not in CJK_OUTSIDE_VIEWS:
            continue
        for line, _, text in literals(source):
            if CJK_RE.search(text):
                found.append(f"{relative}:{line}: Chinese literal outside Views/, use a catalogue key "
                             f"or an English diagnostic: {text!r}")
    return found


def chinese_self_test(files: list[tuple[str, bool, str]]) -> list[str]:
    """A Chinese literal in each watched layer is found; one in a comment,
    or in a layer not watched, is not."""
    baseline = set(chinese_outside_views(files))
    failures: list[str] = []
    app = str(APP.relative_to(REPO_ROOT))
    for layer in CJK_OUTSIDE_VIEWS:
        mutant = (f"{app}/{layer}/SelfTest.swift", False, 'let s = "等待"\n')
        if not set(chinese_outside_views([*files, mutant])) - baseline:
            failures.append(f"self-test: Chinese literal in {layer}/ not found")
    # Found on the right line after comments that end late: a nested block
    # comment, and a comment with a quote inside an interpolation.
    for source, line in [('/* Outer /* inner */\n*/\nlet s = "等待"\n', 3),
                         ('let t = "\\(1 /* " */)"\nlet s = "等待"\n', 2),
                         ('let raw = #"a "quoted" \\#(x) b"#\nlet s = "等待"\n', 2)]:
        mutant = (f"{app}/Editor/SelfTest.swift", False, source)
        if not any(f"SelfTest.swift:{line}:" in p for p in set(chinese_outside_views([*files, mutant])) - baseline):
            failures.append(f"self-test: Chinese literal after a comment not found: {source.strip()!r}")
    for mutant in [(f"{app}/Editor/SelfTest.swift", False, "// 等待\n/* 等待 */\n"),
                   (f"{app}/Editor/SelfTest.swift", False, '/* Outer /* inner */\nlet text = "等待"\n*/\n'),
                   (f"{app}/Editor/SelfTest.swift", False, 'let t = "\\(1 /* "等待" */)"\n'),
                   (f"{app}/Resources/SelfTest.swift", False, 'let s = "等待"\n')]:
        if set(chinese_outside_views([*files, mutant])) - baseline:
            failures.append(f"self-test: not a watched Chinese literal, but found: {mutant[0]}")
    return failures


def boundary_self_test(files: list[tuple[str, bool, str]]) -> list[str]:
    """An engine import must be reported in a view, on the line of its
    `import`, and nowhere else: not outside `Views/`, and not in a comment or
    a string."""
    baseline = set(engine_imports(files))
    failures: list[str] = []
    # (source after "import SwiftUI\n", line of the `import` keyword)
    imports = [
        ("import HyperDREngine\n", 2),
        ("@preconcurrency import HyperDREngine\n", 2),
        ("import struct HyperDREngine.FrameLayout\n", 2),
        ("internal import HyperDREngine\n", 2),
        ("public import HyperDREngine\n", 2),
        ("package import HyperDREngine\n", 2),
        ("fileprivate import HyperDREngine\n", 2),
        ("private import HyperDREngine\n", 2),
        ("@_exported import HyperDREngine\n", 2),
        ("@_spi(Testing) @preconcurrency internal import HyperDREngine\n", 2),
        ("@_exported\nimport HyperDREngine\n", 3),
        ('let a = "/*" // */\nimport HyperDREngine\n', 3),
        # Reviewer-sol's edge cases (Frontend-P2-rereview): a quote in a
        # comment inside an interpolation must not swallow the rest of the
        # file; attributes and a comment before an access-level kind import.
        ('let text = "\\(1 /* " */)"\nimport HyperDREngine\n', 3),
        ('let text = """\n\\(1 // "\n)\n"""\nimport HyperDREngine\n', 6),
        ('@_spi(Testing)\n/* c */\ninternal import struct HyperDREngine.FrameLayout\n', 4),
    ]
    for source, line in imports:
        view = ("apps/apple/HyperDR/Views/SelfTest.swift", True, "import SwiftUI\n" + source)
        if not any(f"SelfTest.swift:{line}:" in p for p in set(engine_imports([*files, view])) - baseline):
            failures.append(f"self-test: engine import in a view not reported: {source.strip()!r}")
    not_imports = [
        "// import HyperDREngine\n",
        "/*\nimport HyperDREngine\n*/\n",
        "/* outer /* inner */\nimport HyperDREngine\n*/\n",
        'let text = """\nimport HyperDREngine\n"""\n',
        'let raw = #"""\nimport HyperDREngine\n"""#\n',
        'let raw = ##"""\nimport HyperDREngine\n"""##\n',
        'let text = "\\(1 /* \\(") */)"\n/*\nimport HyperDREngine\n*/\n',
        'let mixed = """\n\\(f("x"))\nimport HyperDREngine\n"""\n',
        "import HyperDREngineExtras\n",
    ]
    for source in not_imports:
        view = ("apps/apple/HyperDR/Views/SelfTest.swift", True, "import SwiftUI\n" + source)
        if set(engine_imports([*files, view])) - baseline:
            failures.append(f"self-test: not an engine import, but reported: {source.strip()!r}")
    editor = ("apps/apple/HyperDR/Editor/SelfTest.swift", False, "import HyperDREngine\n")
    if set(engine_imports([*files, editor])) - baseline:
        failures.append("self-test: engine import outside Views/ reported")
    return failures


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
        # A key built at run time is not unused; a stray key is.
        ("a catalogue key under a dynamic prefix is not unused",
         "", [f"{DYNAMIC_PREFIXES[0]}zzselftest.label"], None),
        ("a catalogue key outside the prefixes is unused",
         "", ["zzselftest.orphan"], ["unused catalogue key: 'zzselftest.orphan'"]),
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


def design_self_test(files: list[tuple[str, bool, str]], entries: dict) -> list[str]:
    """The package rules: a key read without `bundle: .module`, a missing
    key, and Chinese in a component must each be reported."""
    baseline = set(check(files, entries, module_bundle=True))
    used_key = next(key for key in sorted(entries) if "%@" not in key)
    component = "apps/apple/Packages/HyperDRDesign/Sources/HyperDRDesign/Inspector/SelfTest.swift"
    mutations = [
        ("a package key read from the app bundle",
         f'Text("{used_key}")', ["without `bundle: .module`", repr(used_key)]),
        ("a missing package key",
         'Text("design.zzselftest", bundle: .module)', ["key not in catalogue", "'design.zzselftest'"]),
        ("Chinese in a component",
         'Text(verbatim: "重置")', ["Chinese literal"]),
    ]
    failures: list[str] = []
    for name, source, expected in mutations:
        found = set(check([*files, (component, True, source + "\n")], entries, module_bundle=True)) - baseline
        if not any(all(fragment in problem for fragment in expected) for problem in found):
            failures.append(f"self-test: {name}: not reported (got {sorted(found)})")
    return failures


HEIF_FEATURE_RE = re.compile(r'"([a-z0-9_]+)"')


def heif_engine_sources() -> dict[str, str]:
    """The text of every engine source file that mentions HeifReadError."""
    sources: dict[str, str] = {}
    for pattern in HEIF_SOURCE_GLOBS:
        for path in sorted(REPO_ROOT.glob(pattern)):
            if path.suffix in HEIF_SOURCE_SUFFIXES and path.is_file():
                text = path.read_text(encoding="utf-8", errors="replace")
                if "HeifReadError(" in text:
                    sources[str(path.relative_to(REPO_ROOT))] = text
    return sources


def heif_features_thrown(source: str) -> set[str]:
    """Every lower-case identifier string inside a `HeifReadError(...)` call, up
    to its statement's `;`, whichever branch of a (nested) conditional it is in.
    A message has spaces, so it is not one."""
    found: set[str] = set()
    for call in re.finditer(r"HeifReadError\(", source):
        end = source.find(";", call.end())
        found.update(HEIF_FEATURE_RE.findall(source[call.end():end if end >= 0 else len(source)]))
    return found


def heif_feature_list(error_text: str) -> set[str] | None:
    match = re.search(r"static let heifFeatures\s*=\s*\[([^\]]*)\]", error_text)
    return None if match is None else set(HEIF_FEATURE_RE.findall(match.group(1)))


def heif_features(sources: dict[str, str], error_text: str, entries: dict) -> list[str]:
    """Problems between the features the engine throws, the app's list and the catalogue."""
    if not sources:
        return ["no engine source throws HeifReadError: the source globs found nothing"]
    listed = heif_feature_list(error_text)
    if listed is None:
        return ["cannot find ErrorText.heifFeatures"]
    thrown: set[str] = set()
    for text in sources.values():
        thrown |= heif_features_thrown(text)
    problems = []
    for feature in sorted(thrown - listed):
        problems.append(f"HEIF feature {feature!r} is thrown by the engine but not in ErrorText.heifFeatures")
    for feature in sorted(listed - thrown):
        problems.append(f"ErrorText.heifFeatures has {feature!r}, which no engine source throws")
    for feature in sorted(thrown | listed):
        entry = entries.get(HEIF_FEATURE_KEY + feature)
        for locale in LOCALES:
            value = ((entry or {}).get("localizations", {}).get(locale, {}).get("stringUnit", {}).get("value", ""))
            if not value.strip():
                problems.append(f"HEIF feature {feature!r} has no {locale} sentence ({HEIF_FEATURE_KEY}{feature})")
    return problems


def heif_self_test(sources: dict[str, str], error_text: str, entries: dict) -> list[str]:
    failures = []
    ternary = 'throw HeifReadError("a message", a ? "one_x" : b ? "two_y" : "three_z");\nHeifReadError("two words", "four_w")'
    if heif_features_thrown(ternary) != {"one_x", "two_y", "three_z", "four_w"}:
        failures.append(f"self-test: ternary branches: {sorted(heif_features_thrown(ternary))}")
    if baseline := heif_features(sources, error_text, entries):
        return failures + baseline
    first = next(iter(sources))
    mutant = dict(sources, **{first: sources[first] + '\nHeifReadError("a message", c ? "a_b" : "zzselftest_feature");'})
    if not any("'zzselftest_feature'" in p for p in heif_features(mutant, error_text, entries)):
        failures.append("self-test: a new feature in a later ternary branch not reported")
    listed = sorted(heif_feature_list(error_text) or [])
    dropped = error_text.replace(f'"{listed[0]}"', '"zzselftest_gone"', 1)
    if not any(listed[0] in p for p in heif_features(sources, dropped, entries)):
        failures.append("self-test: a feature missing from the list not reported")
    thin = {k: v for k, v in entries.items() if k != HEIF_FEATURE_KEY + listed[0]}
    if not any(listed[0] in p and "sentence" in p for p in heif_features(sources, error_text, thin)):
        failures.append("self-test: a feature without a sentence not reported")
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

    try:
        design_catalog = json.loads(DESIGN_CATALOG.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        print(f"cannot read {DESIGN_CATALOG.relative_to(REPO_ROOT)}: {error}")
        return 1
    design_entries: dict = design_catalog.get("strings", {})
    design_files = [
        (str(path.relative_to(REPO_ROOT)), DESIGN_COMPONENTS in path.parents, path.read_text(encoding="utf-8"))
        for path in sorted(DESIGN.rglob("*.swift"))
    ]

    try:
        heif_sources = heif_engine_sources()
        error_text = ERROR_TEXT.read_text(encoding="utf-8")
    except OSError as error:
        print(f"cannot read the HEIF feature sources: {error}")
        return 1

    problems = (self_test(files, entries) + heif_self_test(heif_sources, error_text, entries) + design_self_test(design_files, design_entries)
                + boundary_self_test(files) + chinese_self_test(files))
    if "--self-test" not in sys.argv[1:]:
        for name, document in (("app", catalog), ("design package", design_catalog)):
            if document.get("sourceLanguage") != "en":
                problems.append(f"{name} catalogue sourceLanguage must be 'en'")
        problems += check(files, entries)
        problems += engine_imports(files)
        problems += heif_features(heif_sources, error_text, entries)
        outside = chinese_outside_views(files)
        if CJK_OUTSIDE_VIEWS_STRICT:
            problems += outside
        else:
            for warning in outside:
                print(f"warning: {warning}")
        problems += check(design_files, design_entries, module_bundle=True)

    for problem in problems:
        print(problem)
    if problems:
        print(f"\n{len(problems)} problem(s)")
        return 1
    if "--self-test" in sys.argv[1:]:
        print("ok: self-test")
    else:
        print(f"ok: {len(entries)} app keys, {len(design_entries)} design package keys, "
              f"{len(LOCALES)} locales, no engine imports in views (self-test passed)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
