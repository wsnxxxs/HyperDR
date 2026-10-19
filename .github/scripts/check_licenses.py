"""Reject GPL dependencies from installed vcpkg metadata and the CMake link graph.

LGPL libraries remain allowed during the documented desktop transition. Their
copyright files include GPL text by reference, so classify those notices by the
installed SPDX package license, rather than matching that incorporated text.
The checks follow installed metadata and the generated product graph; image
codec dependencies have no separately fetched reference-codec exception list.
"""
import argparse
import json
from pathlib import Path
import re
import subprocess

GPL = re.compile(r"\b(?:A?GPL)(?:[-\s]|$)", re.I)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("build", type=Path)
    parser.add_argument("--triplet", default="arm64-osx")
    args = parser.parse_args()
    share = args.build / "vcpkg_installed" / args.triplet / "share"
    if not share.is_dir():
        raise RuntimeError(f"Missing installed license directory: {share}")
    failures = []
    notices = sorted(share.glob("*/copyright"))
    if not notices:
        raise RuntimeError("No installed copyright files were found")
    for notice in notices:
        package = notice.parent.name
        content = notice.read_text(errors="replace")
        spdx = notice.with_name("vcpkg.spdx.json")
        licenses = []
        if spdx.is_file():
            for entry in json.loads(spdx.read_text()).get("packages", []):
                for key in ("licenseConcluded", "licenseDeclared"):
                    value = entry.get(key, "NOASSERTION")
                    if value not in ("NOASSERTION", "NONE"):
                        licenses.append(value)
        if any(GPL.search(value) for value in licenses):
            failures.append(f"{package}: installed SPDX license {licenses}")
        # Scan every notice too. A declared LGPL notice may embed the GPL
        # document; standalone GPL notices are forbidden, including unknown ports.
        lgpl = bool(re.search(r"\bLGPL\b|LESSER\s+GENERAL\s+PUBLIC\s+LICENSE", content, re.I))
        gpl = bool(GPL.search(content) or re.search(r"GNU\s+GENERAL\s+PUBLIC\s+LICENSE", content, re.I))
        if gpl and not lgpl:
            failures.append(f"{package}: GPL copyright notice")
    graph = args.build / "license-link-graph.dot"
    subprocess.run(["cmake", f"--graphviz={graph.resolve()}", str(args.build.resolve())], check=True,
                   stdout=subprocess.DEVNULL)
    linked = graph.read_text()
    # These optional codec families are GPL; reject them even if a package
    # incorrectly labels its notice or attempts to use a system-installed copy.
    for pattern in (r"\bx265\b", r"\bx264\b", r"\b(?:postproc|avfilter)\b"):
        if re.search(pattern, linked, re.I):
            failures.append(f"forbidden GPL codec in CMake link graph: {pattern}")
    binaries = [args.build / "HyperDR", args.build / "libhyperdr.dylib"]
    for binary in binaries:
        deps = subprocess.check_output(["otool", "-L", str(binary)], text=True)
        if re.search(r"(?:libx26[45]|libpostproc|libavfilter)", deps, re.I):
            failures.append(f"forbidden GPL runtime dependency: {binary}")
    if failures:
        raise RuntimeError("\n".join(failures))
    print(f"License gate passed: {len(notices)} installed copyright/SPDX records, CMake graph, Mach-O dependencies")

if __name__ == "__main__":
    main()
