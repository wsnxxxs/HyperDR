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


def run(*command: str, label: str | None = None, **kwargs) -> None:
    print("+ " + (label or " ".join(map(str, command))), flush=True)
    subprocess.run(command, cwd=ROOT, check=True, **kwargs)


def panel() -> None:
    run(sys.executable, "-m", "pytest", "tests/python", "-q")
    run("pwsh", "-NoProfile", "-File", "tests/powershell/test_hyperdr_tls.ps1")


def frontend() -> None:
    for source in sorted((ROOT / "apps/panel/web/js").rglob("*.js")):
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
    candidates = [build_dir / folder / "HyperDR.exe" for folder in (
        f"modules/app/{config}", "modules/app", config, "",
    )]
    executable = next((path for path in candidates if path.is_file()), None)
    if executable is None:
        raise RuntimeError(f"No HyperDR.exe in {build_dir} for {config}")
    env = dict(os.environ, HYPERDR_EXECUTABLE=str(executable))
    run(sys.executable, "-m", "unittest", "discover", "-s", "tests/native", env=env)
    json.loads((ROOT / "schema/report.json").read_text(encoding="utf-8"))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("suite", choices=("all", "panel", "frontend", "native"),
                        nargs="?", default="all")
    parser.add_argument("--build-dir", default="build-core",
                        help="Configured CMake build directory (default: build-core)")
    parser.add_argument("--config", default="Release")
    args = parser.parse_args()
    try:
        if args.suite in ("all", "panel"):
            panel()
        if args.suite in ("all", "frontend"):
            frontend()
        if args.suite in ("all", "native"):
            native((ROOT / args.build_dir).resolve(), args.config)
    except (subprocess.CalledProcessError, OSError, RuntimeError, ValueError) as error:
        print(f"Tests failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
