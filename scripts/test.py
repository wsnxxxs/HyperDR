"""Shared local/CI test entry point; native tests use an explicitly selected build."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
from xml.parsers.expat import ExpatError

from engine_fingerprint import engine_fingerprint

ROOT = Path(__file__).resolve().parents[1]
MINIMUM_PYTHON = (3, 10)

if sys.version_info < MINIMUM_PYTHON:
    raise SystemExit(
        "HyperDR tests require Python 3.10 or newer (3.12 is recommended and used by CI).\n"
        f"Current interpreter: {sys.version.split()[0]} ({sys.executable})\n"
        "Select a newer interpreter explicitly, for example:\n"
        '  PATH="$(brew --prefix python@3.12)/libexec/bin:$PATH" python3 scripts/test.py apple\n'
        "  python3.12 scripts/test.py apple")

APPLE_PACKAGES = {
    "HyperDREngine": "swift-engine",
    "HyperDRKit": "swift-kit",
    "HyperDRDesign": "swift-design",
    "HyperDRRecipe": "swift-recipe",
    "HyperDRRender": "swift-render",
    "HyperDREditorCore": "swift-editor-core",
}
APPLE_DEVELOPER_DIR = Path("/Applications/Xcode.app/Contents/Developer")


def run(*command: str, label: str | None = None, **kwargs) -> None:
    print("+ " + (label or " ".join(map(str, command))), flush=True)
    subprocess.run(command, cwd=ROOT, check=True, **kwargs)


def native(build_dir: Path, config: str) -> None:
    run("cmake", "--build", str(build_dir), "--config", config, "--parallel")
    run("ctest", "--test-dir", str(build_dir), "-C", config,
        "--output-on-failure", "--no-tests=error")
    # CMake's module layout, plus the older root output layout in local builds.
    name = "HyperDR.exe" if os.name == "nt" else "HyperDR"
    candidates = [build_dir / folder / name for folder in (
        f"modules/app/{config}", "modules/app", config, "",
    )]
    executable = next((path for path in candidates if path.is_file()), None)
    if executable is None:
        raise RuntimeError(f"No {name} in {build_dir} for {config}")
    env = dict(os.environ, HYPERDR_EXECUTABLE=str(executable))
    run(sys.executable, "-m", "unittest", "discover", "-s", "tests/native", env=env)
    json.loads((ROOT / "schema/report.json").read_text(encoding="utf-8"))


def ensure_metal_toolchain(env: dict[str, str]) -> None:
    result = subprocess.run(
        ("xcodebuild", "-showComponent", "MetalToolchain"),
        cwd=ROOT, env=env, capture_output=True, text=True)
    if result.returncode != 0 or "Status: installed" not in result.stdout:
        raise RuntimeError(
            "Metal Toolchain is not installed. Install it with:\n"
            "  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer "
            "xcodebuild -downloadComponent MetalToolchain")


def xcode_env() -> dict[str, str]:
    developer_dir = Path(os.environ.get("DEVELOPER_DIR", APPLE_DEVELOPER_DIR))
    if not (developer_dir / "usr/bin/xcodebuild").is_file():
        raise RuntimeError(
            f"Xcode was not found at {developer_dir}. Set DEVELOPER_DIR to an Xcode "
            "developer directory or run: sudo xcode-select -s /Applications/Xcode.app")
    return dict(os.environ, DEVELOPER_DIR=str(developer_dir))


def apple() -> None:
    env = xcode_env()
    ensure_metal_toolchain(env)
    # The build script gates every archive it produces with check_licenses.py
    # --archive-only (R7-1602), so a slice can never be built, or skipped, without
    # the libheif/libde265 check.
    ensure_apple_engine(env, ios=False)
    for package, scratch in APPLE_PACKAGES.items():
        path = ROOT / "apps/apple/Packages" / package
        if not path.is_dir():
            print(f"Skipping {package}: package is not present yet", flush=True)
            continue
        run("swift", "test", "--package-path", str(path),
            "--scratch-path", str(ROOT / "build-apple" / scratch), env=env)
    xcode = ("xcodebuild", "-project", "apps/apple/HyperDR.xcodeproj", "-scheme", "HyperDR",
             "-destination", "platform=macOS", "-derivedDataPath", "build-apple/DerivedData")
    run(*xcode, "build", env=env)
    run(*xcode, "test", "-test-timeouts-enabled", "YES",
        "-default-test-execution-time-allowance", "60", env=env)
    run(sys.executable, "scripts/check_apple_i18n.py")
    run(sys.executable, "scripts/summarize_preview_timings.py", "--self-test")
    run(sys.executable, "tests/apple/export_parity.py", env=env)


def has_apple_engine_slices(*, ios: bool = True) -> bool:
    """Check usable macOS and, when requested, both arm64 iOS variants.
    A plist entry alone is insufficient after an interrupted or Mac-only build.
    """
    artifact = ROOT / "apps/apple/Packages/HyperDREngine/Artifacts/HyperDREngineCore.xcframework"
    try:
        with (artifact / "Info.plist").open("rb") as file:
            metadata = plistlib.load(file)
        if not isinstance(metadata, dict):
            return False
        libraries = metadata.get("AvailableLibraries", [])
        if not isinstance(libraries, list):
            return False
        found = set()
        for library in libraries:
            if not isinstance(library, dict) or "arm64" not in library.get("SupportedArchitectures", []):
                continue
            identifier = library.get("LibraryIdentifier")
            binary = library.get("LibraryPath")
            headers = library.get("HeadersPath")
            if not all(isinstance(value, str) and value for value in (identifier, binary, headers)):
                continue
            directory = artifact / identifier
            archive = directory / binary
            if not archive.is_file() or archive.stat().st_size == 0:
                continue
            if not all((directory / headers / name).is_file() for name in ("hyperdr.h", "module.modulemap")):
                continue
            found.add((library.get("SupportedPlatform"), library.get("SupportedPlatformVariant", "")))
        required = {("macos", ""), ("ios", ""), ("ios", "simulator")} if ios else {("macos", "")}
        return required <= found
    except (OSError, ValueError, TypeError, plistlib.InvalidFileException, ExpatError):
        return False


def ensure_apple_engine(env: dict[str, str], *, ios: bool) -> None:
    artifact = ROOT / "apps/apple/Packages/HyperDREngine/Artifacts/HyperDREngineCore.xcframework"
    fingerprint = engine_fingerprint(ROOT)

    def current() -> bool:
        try:
            return has_apple_engine_slices(ios=ios) and (
                artifact.resolve().parent / "engine-source.sha256").read_text().strip() == fingerprint
        except OSError:
            return False

    if current():
        return
    command = ("bash", "scripts/build_xcframework.sh")
    if ios:
        command += ("--platforms", "all")
    run(*command, env=env)
    if not has_apple_engine_slices(ios=ios):
        raise RuntimeError("Engine xcframework is missing usable requested slices after rebuilding")
    if not current():
        raise RuntimeError("Engine xcframework source stamp is missing or stale after rebuilding")


def ensure_ios_engine(env: dict[str, str]) -> None:
    ensure_apple_engine(env, ios=True)


def ios() -> None:
    """The iOS and iPadOS target: device and simulator builds, unsigned (no
    team needed). Needs Xcode's iOS platform; the Mac suite does not."""
    env = xcode_env()
    ensure_metal_toolchain(env)
    ensure_ios_engine(env)
    for destination in ("generic/platform=iOS", "generic/platform=iOS Simulator"):
        run("xcodebuild", "-project", "apps/apple/HyperDR.xcodeproj", "-scheme", "HyperDRiOS",
            "-destination", destination, "-derivedDataPath", "build-apple/DerivedData-iOS",
            "CODE_SIGNING_ALLOWED=NO", "build", env=env)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("suite", choices=("all", "native", "apple", "ios"),
                        nargs="?", default="all")
    parser.add_argument("--build-dir", default="build-core",
                        help="Configured CMake build directory (default: build-core)")
    parser.add_argument("--config", default="Release")
    args = parser.parse_args()
    try:
        if args.suite in ("all", "native"):
            native((ROOT / args.build_dir).resolve(), args.config)
        if args.suite == "apple":
            apple()
        if args.suite == "ios":
            ios()
    except (subprocess.CalledProcessError, OSError, RuntimeError, ValueError) as error:
        print(f"Tests failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
