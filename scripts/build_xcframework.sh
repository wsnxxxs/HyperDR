#!/bin/bash
# macOS arm64 only. Build products stay local; the engine is one static library
# with no dylib to embed.
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$repo/build-apple"
out="$repo/build/xcframework"
git -C "$repo" check-ignore -q "$work/probe" || { echo 'build-apple must be gitignored' >&2; exit 1; }
# CI checks vcpkg out separately; local checkouts commonly live at ~/vcpkg.
# The first argument or VCPKG_ROOT selects an explicit toolchain.
vcpkg_root="${1:-${VCPKG_ROOT:-}}"
if [[ -z "$vcpkg_root" ]]; then
  for candidate in "$HOME/vcpkg" "$repo/build-vcpkg"; do
    if [[ -f "$candidate/scripts/buildsystems/vcpkg.cmake" ]]; then vcpkg_root="$candidate"; break; fi
  done
fi
if [[ -z "$vcpkg_root" ]]; then
  echo 'vcpkg toolchain not found. Set VCPKG_ROOT, pass the vcpkg checkout path as the first argument, or check out vcpkg at build-vcpkg.' >&2
  exit 1
fi
toolchain="$vcpkg_root/scripts/buildsystems/vcpkg.cmake"
if [[ ! -f "$toolchain" ]]; then
  echo "vcpkg toolchain not found: $toolchain" >&2
  exit 1
fi
echo "Using vcpkg toolchain: $toolchain"
cmake --preset macos-arm64-codecs -S "$repo" -B "$work" -DHYPERDR_BUILD_TESTS=OFF \
  -DCMAKE_TOOLCHAIN_FILE="$toolchain"
cmake --build "$work" --target hyperdr_capi_static HyperDR
rm -rf "$out/Runtime"  # earlier builds staged dylibs here
mkdir -p "$out/headers"
cp "$repo/modules/capi/include/hyperdr/hyperdr.h" "$out/headers/"
cp "$repo/apps/apple/Packages/HyperDREngine/Modules/module.modulemap" "$out/headers/"
# Read CMake's generated link line so the archive follows the actual static
# dependency closure without maintaining a second C++ graph.
python3 - "$work" "$out" <<'PY'
import pathlib, shlex, subprocess, sys
work, out = map(pathlib.Path, sys.argv[1:])
commands = subprocess.check_output(['ninja', '-C', str(work), '-t', 'commands', 'HyperDR'], text=True)
line = next(line for line in commands.splitlines() if ' -o HyperDR ' in line)
tokens = shlex.split(line)
archives = [work / 'libhyperdr.a']
for token in tokens:
    if token.endswith('.a'):
        path = pathlib.Path(token)
        path = path if path.is_absolute() else work / path
        if path not in archives: archives.append(path)
# CMake enables Release LTO. Materialize bitcode before packaging: Xcode's
# xcframework scanner cannot infer an architecture from LLVM-only members.
subprocess.run(['xcrun', 'ld', '-r', '-arch', 'arm64', '-platform_version', 'macos', '26.0', '26.0',
                '-all_load', *map(str, archives), '-o', str(out / 'HyperDREngineCore.o')], check=True)
subprocess.run(['xcrun', 'libtool', '-static', '-o', str(out / 'libHyperDREngineCore.a'),
                str(out / 'HyperDREngineCore.o')], check=True)
PY
rm -rf "$out/HyperDREngineCore.xcframework"
xcodebuild -create-xcframework -library "$out/libHyperDREngineCore.a" -headers "$out/headers" -output "$out/HyperDREngineCore.xcframework"
mkdir -p "$repo/apps/apple/Packages/HyperDREngine/Artifacts"
ln -sfn ../../../../../build/xcframework/HyperDREngineCore.xcframework "$repo/apps/apple/Packages/HyperDREngine/Artifacts/HyperDREngineCore.xcframework"
"$work/HyperDR" schema > "$out/schema-cli.json"
echo "Built macOS arm64: $out/HyperDREngineCore.xcframework"
