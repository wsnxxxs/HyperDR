#!/bin/bash
# macOS arm64 only. Build products and replaceable decoder dylibs stay local.
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
cmake --build "$work" --target hyperdr_capi_static HyperDR uhdr-static
rm -rf "$out/Runtime"
mkdir -p "$out/headers" "$out/Runtime"
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
# libultrahdr supplies an explicitly combined static target even while the CLI
# uses its shared target. This leaves only the transitional LGPL decoders dynamic.
archives.append(work / '_deps/libuhdr-build/libuhdr.a')
# CMake enables Release LTO. Materialize bitcode before packaging: Xcode's
# xcframework scanner cannot infer an architecture from LLVM-only members.
subprocess.run(['xcrun', 'ld', '-r', '-arch', 'arm64', '-platform_version', 'macos', '26.0', '26.0',
                '-all_load', *map(str, archives), '-o', str(out / 'HyperDREngineCore.o')], check=True)
subprocess.run(['xcrun', 'libtool', '-static', '-o', str(out / 'libHyperDREngineCore.a'),
                str(out / 'HyperDREngineCore.o')], check=True)
# Stage the non-system dylib closure; preserve replaceability and use @rpath IDs.
pending = [pathlib.Path(t) if pathlib.Path(t).is_absolute() else work / t
           for t in tokens if t.endswith('.dylib') and 'libuhdr' not in t]
seen = set()
while pending:
    source = pending.pop().resolve()
    if source in seen: continue
    seen.add(source)
    destination = out / 'Runtime' / source.name
    destination.write_bytes(source.read_bytes())
    destination.chmod(0o755)
    deps = subprocess.check_output(['otool', '-L', str(source)], text=True).splitlines()[2:]
    changes = []
    for entry in deps:
        dep = entry.strip().split(' (')[0]
        if dep.startswith(('/usr/lib/', '/System/Library/')): continue
        path = pathlib.Path(dep)
        if dep.startswith('@rpath/'):
            path = source.parent / dep.removeprefix('@rpath/')
        elif dep.startswith('@loader_path/'):
            path = source.parent / dep.removeprefix('@loader_path/')
        if not path.exists(): raise RuntimeError(f'Unresolved dependency: {source}: {dep}')
        pending.append(path)
        changes += ['-change', dep, '@rpath/' + path.resolve().name]
    subprocess.run(['install_name_tool', '-id', '@rpath/' + source.name, *changes, str(destination)], check=True)
    subprocess.run(['codesign', '--force', '--sign', '-', str(destination)], check=True)
    # The linker accepts the unversioned spelling; dyld uses the versioned ID.
    name = source.name.split('.')[0] + '.dylib'
    alias = destination.parent / name
    if alias != destination:
        alias.unlink(missing_ok=True)
        alias.symlink_to(destination.name)
    print(f'Replaceable runtime: {destination}')
PY
rm -rf "$out/HyperDREngineCore.xcframework"
xcodebuild -create-xcframework -library "$out/libHyperDREngineCore.a" -headers "$out/headers" -output "$out/HyperDREngineCore.xcframework"
mkdir -p "$repo/apps/apple/Packages/HyperDREngine/Artifacts"
ln -sfn ../../../../../build/xcframework/HyperDREngineCore.xcframework "$repo/apps/apple/Packages/HyperDREngine/Artifacts/HyperDREngineCore.xcframework"
"$work/HyperDR" schema > "$out/schema-cli.json"
echo "Built macOS arm64: $out/HyperDREngineCore.xcframework"
echo "App bundles must embed and sign $out/Runtime/*.dylib (libheif/libde265)."
