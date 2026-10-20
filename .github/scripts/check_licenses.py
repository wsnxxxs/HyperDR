"""Reject GPL and LGPL dependencies from installed vcpkg metadata, the CMake link
graph and the product binaries.

Nothing HyperDR ships may be (L)GPL: every dependency is statically linked and
permissively licensed, with no replaceable-library exception. An LGPL package
is therefore a failure, as is any trace of libheif or libde265 (retired in
P3b-5) in the link graph or in the Mach-O dependencies and undefined symbols
of the CLI and the C ABI library.
The checks follow installed metadata and the generated product graph; image
codec dependencies have no separately fetched reference-codec exception list.

Two further checks cover what the link graph cannot: every installed vcpkg
package must be listed in THIRD_PARTY_NOTICES.md (so a new dependency cannot
ship unannounced), and the static engine archive the app really links
(``libHyperDREngineCore.a``, built by scripts/build_xcframework.sh) must define
no libheif or libde265 symbols.
"""
import argparse
import json
from pathlib import Path
import re
import subprocess

GPL = re.compile(r"\b(?:A?GPL)(?:[-\s]|$)", re.I)
LGPL = re.compile(r"\bLGPL\b|LESSER\s+GENERAL\s+PUBLIC\s+LICENSE", re.I)
# Packages whose notice lists (L)GPL for parts that are not the library we link.
# Each entry is accepted only while the notice still states the library's own
# permissive license in the quoted words.
MIXED_NOTICES = {
    # xz's tools (getopt_long) and shell scripts are LGPL/GPL and not built; the
    # library, the only part vcpkg installs here, is 0BSD.
    "liblzma": "liblzma is under the BSD Zero Clause License (0BSD)",
}
# vcpkg port name -> the name the THIRD_PARTY_NOTICES.md table must contain.
# vcpkg-* ports are build tooling and are not shipped.
NOTICE_NAMES = {
    "aom": "libaom",
    "lcms": "Little CMS",
    "libavif": "libavif",
    "libjpeg-turbo": "libjpeg-turbo",
    "liblzma": "liblzma",
    "libpng": "libpng",
    "libyuv": "libyuv",
    "ncnn": "ncnn",
    "tiff": "libtiff",
    "zlib": "zlib",
}
NOTICES = Path(__file__).resolve().parents[2] / "THIRD_PARTY_NOTICES.md"
# Defined symbols of the retired libraries: libheif's C API (heif_context_*,
# heif_image_*, ...), its C++ namespace, and libde265's de265_* API.
RETIRED_HEIF_DEFINED = re.compile(r"^\S+\s+[TtSsDdBbRrWw]\s+(?:_heif_[a-z0-9]+_|_de265_|__ZN\d*heif\d*|__ZN\d+de265)", re.M)
RETIRED_HEIF = re.compile(r"libheif|libde265|label\s*=\s*\"(?:heif|de265)\"", re.I)

def installed_ports(build, triplet):
    """Names of the vcpkg ports installed for the product, without build tooling."""
    info = build / "vcpkg_installed" / "vcpkg" / "info"
    if not info.is_dir():
        raise RuntimeError(f"Missing vcpkg package list directory: {info}")
    ports = {entry.name.rsplit("_", 2)[0] for entry in info.glob(f"*_{triplet}.list")}
    return sorted(port for port in ports if not port.startswith("vcpkg-"))

def check_notices(build, triplet):
    notices = NOTICES.read_text()
    table = [line for line in notices.splitlines() if line.startswith("|")]
    failures = []
    for port in installed_ports(build, triplet):
        name = NOTICE_NAMES.get(port)
        if name is None:
            failures.append(f"{port}: installed vcpkg package is not known to the license gate; "
                            "add it to THIRD_PARTY_NOTICES.md and NOTICE_NAMES")
        elif not any(name in row.split("|")[1] for row in table):
            failures.append(f"{port}: installed but missing from the {NOTICES.name} table (expected '{name}')")
    return failures

def check_engine_archive(archive):
    """The static library the app links must not carry libheif or libde265."""
    if not archive.is_file():
        raise RuntimeError(f"Missing engine archive: {archive}")
    symbols = subprocess.check_output(["nm", str(archive)], text=True, stderr=subprocess.DEVNULL)
    found = sorted({match.group(0).split()[-1] for match in RETIRED_HEIF_DEFINED.finditer(symbols)})
    return [f"libheif/libde265 symbols defined in {archive}: {', '.join(found[:5])}"] if found else []

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("build", type=Path)
    parser.add_argument("--triplet", default="arm64-osx")
    parser.add_argument("--engine-archive", type=Path,
                        help="libHyperDREngineCore.a that the app links; also checked for retired symbols")
    parser.add_argument("--archive-only", action="store_true",
                        help="check only --engine-archive (the Apple job has no CLI or dylib to inspect)")
    args = parser.parse_args()
    if args.archive_only:
        if args.engine_archive is None:
            parser.error("--archive-only needs --engine-archive")
        failures = check_engine_archive(args.engine_archive)
        if failures:
            raise RuntimeError("\n".join(failures))
        print(f"License gate passed: {args.engine_archive} defines no libheif/libde265 symbols")
        return
    share = args.build / "vcpkg_installed" / args.triplet / "share"
    if not share.is_dir():
        raise RuntimeError(f"Missing installed license directory: {share}")
    failures = []
    notices = sorted(share.glob("*/copyright"))
    if not notices:
        raise RuntimeError("No installed copyright files were found")
    for notice in notices:
        package = notice.parent.name
        if package.lower() == "libraw":
            failures.append("LibRaw/CDDL dependency was retired in R3")
        content = notice.read_text(errors="replace")
        spdx = notice.with_name("vcpkg.spdx.json")
        licenses = []
        if spdx.is_file():
            for entry in json.loads(spdx.read_text()).get("packages", []):
                for key in ("licenseConcluded", "licenseDeclared"):
                    value = entry.get(key, "NOASSERTION")
                    if value not in ("NOASSERTION", "NONE"):
                        licenses.append(value)
        if any(GPL.search(value) or LGPL.search(value) for value in licenses):
            failures.append(f"{package}: installed SPDX license {licenses}")
        if package.lower() in ("libheif", "libde265"):
            failures.append(f"{package}: retired in P3b-5; HEIF is read by our own code")
        # Scan every notice too: standalone GPL notices are forbidden, including
        # unknown ports, and so is any LGPL notice (which embeds the GPL text).
        mixed = MIXED_NOTICES.get(package.lower())
        if mixed and mixed in content:
            continue
        if LGPL.search(content):
            failures.append(f"{package}: LGPL copyright notice")
        elif GPL.search(content) or re.search(r"GNU\s+GENERAL\s+PUBLIC\s+LICENSE", content, re.I):
            failures.append(f"{package}: GPL copyright notice")
    failures += check_notices(args.build, args.triplet)
    if args.engine_archive is not None:
        failures += check_engine_archive(args.engine_archive)
    graph = args.build / "license-link-graph.dot"
    subprocess.run(["cmake", f"--graphviz={graph.resolve()}", str(args.build.resolve())], check=True,
                   stdout=subprocess.DEVNULL)
    linked = graph.read_text()
    if re.search(r"\blibraw(?:::raw_r)?\b", linked, re.I):
        failures.append("retired LibRaw dependency in CMake link graph")
    # These optional codec families are GPL; reject them even if a package
    # incorrectly labels its notice or attempts to use a system-installed copy.
    if RETIRED_HEIF.search(linked):
        failures.append("retired libheif/libde265 dependency in CMake link graph")
    for pattern in (r"\bx265\b", r"\bx264\b", r"\b(?:postproc|avfilter)\b"):
        if re.search(pattern, linked, re.I):
            failures.append(f"forbidden GPL codec in CMake link graph: {pattern}")
    binaries = [args.build / "HyperDR", args.build / "libhyperdr.dylib"]
    for binary in binaries:
        deps = subprocess.check_output(["otool", "-L", str(binary)], text=True)
        if re.search(r"libraw", deps, re.I):
            failures.append(f"retired LibRaw runtime dependency: {binary}")
        if re.search(r"(?:libx26[45]|libpostproc|libavfilter)", deps, re.I):
            failures.append(f"forbidden GPL runtime dependency: {binary}")
        if re.search(r"libheif|libde265", deps, re.I):
            failures.append(f"retired libheif/libde265 runtime dependency: {binary}")
        undefined = subprocess.check_output(["nm", "-u", str(binary)], text=True, stderr=subprocess.DEVNULL)
        if re.search(r"_heif_|_de265_", undefined):
            failures.append(f"libheif/libde265 symbols still referenced: {binary}")
    if failures:
        raise RuntimeError("\n".join(failures))
    print(f"License gate passed: {len(notices)} installed copyright/SPDX records, CMake graph, Mach-O dependencies")

if __name__ == "__main__":
    main()
