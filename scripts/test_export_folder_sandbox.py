#!/usr/bin/env python3
"""Run fixed-folder export in a signed, windowless App Sandbox host.

Usage: DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer python3 scripts/test_export_folder_sandbox.py
Requires this checkout's xcframework (scripts/test.py apple builds it).
Test-only sandbox SPI grants alpha/beta, never their unselected parent. No GUI.
Builds/logs stay under --build-dir (default build-apple/folder-sandbox).
"""
from __future__ import annotations

import argparse
import ctypes
import json
import hashlib
import os
from pathlib import Path
import plistlib
import queue
import shutil
import subprocess
import tempfile
import threading
import time


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", type=Path, default=Path("build-apple/folder-sandbox"))
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    scratch = args.build_dir.resolve()
    scratch.mkdir(parents=True, exist_ok=True)
    package = scratch / "host-package"
    (package / "Sources").mkdir(parents=True, exist_ok=True)
    shutil.copy2(repo / "tests/apple/ExportFolderSandboxHost.swift", package / "Sources/main.swift")
    kit = repo / "apps/apple/Packages/HyperDRKit"
    (package / "Package.swift").write_text(
        '// swift-tools-version: 6.2\nimport PackageDescription\n'
        'let package = Package(name: "FolderSandbox", platforms: [.macOS(\"15.0\")], '
        f'dependencies: [.package(path: {json.dumps(str(kit))})], targets: ['
        '.executableTarget(name: "FolderSandbox", dependencies: ['
        '.product(name: "HyperDRKit", package: "HyperDRKit")], path: "Sources")])\n'
    )
    env = os.environ.copy()
    env.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
    command = ["swift", "build", "--package-path", str(package), "--scratch-path", str(scratch / "swift")]
    with (scratch / "build.log").open("w") as log:
        subprocess.run(command + ["--product", "FolderSandbox"], env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
    binary_dir = Path(subprocess.check_output(command + ["--show-bin-path"], env=env, text=True).strip())
    bundle = scratch / "FolderSandbox.app"
    if bundle.exists():
        shutil.rmtree(bundle)
    (bundle / "Contents/MacOS").mkdir(parents=True)
    executable = bundle / "Contents/MacOS/FolderSandbox"
    shutil.copy2(binary_dir / "FolderSandbox", executable)
    (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleExecutable": "FolderSandbox", "CFBundleIdentifier": "com.hyperdr.tests.folder-sandbox",
        "CFBundlePackageType": "APPL", "CFBundleVersion": "1",
    }))
    entitlements = scratch / "entitlements.plist"
    entitlements.write_bytes(plistlib.dumps({
        "com.apple.security.app-sandbox": True,
        "com.apple.security.files.user-selected.read-write": True,
        "com.apple.security.files.bookmarks.app-scope": True,
    }))
    subprocess.run(["codesign", "--force", "--deep", "--sign", "-", "--entitlements", str(entitlements), str(bundle)], check=True, capture_output=True)
    subprocess.run(["codesign", "--verify", "--strict", str(bundle)], check=True)
    sandbox = ctypes.CDLL("/usr/lib/libsandbox.1.dylib", use_errno=True)
    issue = sandbox.sandbox_extension_issue_file
    issue.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint32]
    issue.restype = ctypes.c_char_p
    authority = Path(tempfile.mkdtemp(prefix="selected-", dir=scratch))
    process = None
    transcript: list[str] = []
    try:
        grants: list[str] = []
        for name in ["alpha", "beta"]:
            directory = authority / name
            directory.mkdir()
            token = issue(b"com.apple.app-sandbox.read-write", os.fsencode(directory), 0)
            if token is None:
                raise RuntimeError(f"sandbox_extension_issue_file failed: errno={ctypes.get_errno()}")
            grants.extend([token.decode(), str(directory)])
        # Tokens are passed only to the child and are never included in logs.
        process = subprocess.Popen([str(executable), *grants], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, text=True, bufsize=1, env=env)
        lines: queue.Queue[str | None] = queue.Queue()

        def read_output() -> None:
            assert process is not None and process.stdout is not None
            for line in process.stdout:
                lines.put(line)
            lines.put(None)

        threading.Thread(target=read_output, daemon=True).start()
        deadline = time.monotonic() + 90
        while True:
            line = lines.get(timeout=max(0.01, deadline - time.monotonic()))
            if line is None:
                break
            transcript.append(line)
            print(line, end="", flush=True)
            if line.startswith("VERIFY_RENAMED_EXPORT "):
                expected = json.loads(line.split(" ", 1)[1])
                name = expected["name"]
                if Path(name).name != name:
                    raise RuntimeError("Invalid verification filename")
                data = (authority / "alpha-moved" / name).read_bytes()
                if hashlib.sha256(data).hexdigest() != expected["sha256"]:
                    raise RuntimeError("Renamed save differs from the engine result")
                transcript.append("PASS renamed save bytes verified by launcher\n")
                print("PASS renamed save bytes verified by launcher", flush=True)
            if line.strip() == "READY_FOR_PARENT_RENAME":
                (authority / "alpha").rename(authority / "alpha-moved")
                (authority / "alpha").symlink_to(authority / "beta", target_is_directory=True)
                assert process.stdin is not None
                process.stdin.write("RENAMED\n")
                process.stdin.flush()
        code = process.wait(timeout=max(0.01, deadline - time.monotonic()))
        transcript.append(f"exit={code}\n")
        if code != 0 or "EXPORT_FOLDER_SANDBOX_PASSED\n" not in transcript:
            raise RuntimeError(f"Signed sandbox host failed, exit={code}; see {scratch / 'result.log'}")
    finally:
        if process is not None and process.poll() is None:
            process.kill()
            process.wait()
        (scratch / "result.log").write_text("".join(transcript))
        shutil.rmtree(authority)


if __name__ == "__main__":
    main()
