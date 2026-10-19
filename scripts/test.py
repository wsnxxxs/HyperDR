"""Shared local/CI test entry point; native tests use an explicitly selected build."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

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
}
APPLE_DEVELOPER_DIR = Path("/Applications/Xcode.app/Contents/Developer")


def run(*command: str, label: str | None = None, **kwargs) -> None:
    print("+ " + (label or " ".join(map(str, command))), flush=True)
    subprocess.run(command, cwd=ROOT, check=True, **kwargs)


def panel() -> None:
    raise RuntimeError("旧 Python 面板测试已退役，P2c 删除")


def frontend() -> None:
    # The phone tree is parsed too: it is an ES module that imports the editor's
    # own modules, so a syntax error there breaks a real front-end.
    sources = (sorted((ROOT / "apps/panel/web/js").rglob("*.js"))
               + sorted((ROOT / "apps/panel/web/phone").rglob("*.js")))
    for source in sources:
        run("node", "--input-type=module", "--check", input=source.read_bytes(),
            label=f"Parse {source.relative_to(ROOT)}")
    for test in sorted((ROOT / "tests/js").glob("*_test.mjs")):
        run("node", str(test))
    run(sys.executable, "scripts/check_panel_roles.py")
    run(sys.executable, "scripts/check_panel_i18n.py")


def native(build_dir: Path, config: str) -> None:
    if not shutil.which("node"):
        raise RuntimeError("Native curve comparison requires Node.js")
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


def apple() -> None:
    developer_dir = Path(os.environ.get("DEVELOPER_DIR", APPLE_DEVELOPER_DIR))
    if not (developer_dir / "usr/bin/xcodebuild").is_file():
        raise RuntimeError(
            f"Xcode was not found at {developer_dir}. Set DEVELOPER_DIR to an Xcode "
            "developer directory or run: sudo xcode-select -s /Applications/Xcode.app")
    env = dict(os.environ, DEVELOPER_DIR=str(developer_dir))
    ensure_metal_toolchain(env)
    run("bash", "scripts/build_xcframework.sh", env=env)
    for package, scratch in APPLE_PACKAGES.items():
        path = ROOT / "apps/apple/Packages" / package
        if not path.is_dir():
            print(f"Skipping {package}: package is not present yet", flush=True)
            continue
        run("swift", "test", "--package-path", str(path),
            "--scratch-path", str(ROOT / "build-apple" / scratch), env=env)
    if not shutil.which("node"):
        raise RuntimeError("Apple tests require Node.js (the shader comparison invokes node)")
    xcode = ("xcodebuild", "-project", "apps/apple/HyperDR.xcodeproj", "-scheme", "HyperDR",
             "-destination", "platform=macOS", "-derivedDataPath", "build-apple/DerivedData")
    run(*xcode, "build", env=env)
    run(*xcode, "test", "-test-timeouts-enabled", "YES",
        "-default-test-execution-time-allowance", "60", env=env)
    run(sys.executable, "scripts/check_apple_i18n.py")
    run(sys.executable, "tests/apple/export_parity.py", env=env)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("suite", choices=("all", "panel", "frontend", "native", "apple"),
                        nargs="?", default="all")
    parser.add_argument("--build-dir", default="build-core",
                        help="Configured CMake build directory (default: build-core)")
    parser.add_argument("--config", default="Release")
    args = parser.parse_args()
    try:
        if args.suite == "panel":
            panel()
        if args.suite in ("all", "frontend"):
            frontend()
        if args.suite in ("all", "native"):
            native((ROOT / args.build_dir).resolve(), args.config)
        if args.suite == "apple":
            apple()
    except (subprocess.CalledProcessError, OSError, RuntimeError, ValueError) as error:
        print(f"Tests failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
