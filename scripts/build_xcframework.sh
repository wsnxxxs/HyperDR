#!/bin/bash
# Builds the engine xcframework and its static archive.
#
# Default: the macOS arm64 slice only, which is what the Swift package tests and
# the macOS app need (and what CI builds on every run).
#   bash scripts/build_xcframework.sh [VCPKG_ROOT] [--platforms all]
# `--platforms all` adds the iOS device and iOS simulator slices, so the
# xcframework carries the same three slices the multi-platform app links.
#
# Build products stay local; the engine is one static archive per slice with no
# dylib to embed.
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
repo="$(cd "$(dirname "$0")/.." && pwd)"

usage() {
  cat <<'USAGE'
usage: build_xcframework.sh [VCPKG_ROOT] [--platforms macos|all]

  VCPKG_ROOT     vcpkg checkout holding the toolchain (default: $VCPKG_ROOT,
                 ~/vcpkg, or build-vcpkg)
  --platforms    macos (default) or all (macOS + iOS device + iOS simulator)
USAGE
}

platforms=macos
vcpkg_argument=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --platforms)
      platforms="${2:-}"
      [[ -n "$platforms" ]] || { echo '--platforms needs a value' >&2; exit 2; }
      shift 2
      ;;
    --platforms=*)
      platforms="${1#*=}"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ -n "$vcpkg_argument" ]]; then
        echo "unexpected extra argument: $1" >&2
        usage >&2
        exit 2
      fi
      vcpkg_argument="$1"
      shift
      ;;
  esac
done

case "$platforms" in
  macos) slices=(macos) ;;
  all)   slices=(macos ios ios-simulator) ;;
  *)
    echo "unknown --platforms value: $platforms (expected macos or all)" >&2
    exit 2
    ;;
esac

slice_preset() {
  case "$1" in
    macos)         echo macos-arm64-codecs ;;
    ios)           echo ios-arm64-codecs ;;
    ios-simulator) echo ios-simulator-arm64-codecs ;;
  esac
}

slice_build_dir() {
  case "$1" in
    macos)         echo "$repo/build-apple" ;;
    ios)           echo "$repo/build-ios" ;;
    ios-simulator) echo "$repo/build-ios-simulator" ;;
  esac
}

# The <platform> value xcrun ld stamps into the relocatable object.
slice_link_platform() {
  case "$1" in
    macos)         echo macos ;;
    ios)           echo ios ;;
    ios-simulator) echo ios-simulator ;;
  esac
}

# The link line the archive closure is read from: the CLI on macOS, the C ABI
# shared library on iOS, where no executable is built.
slice_closure_target() {
  case "$1" in
    macos) echo HyperDR ;;
    *)     echo hyperdr_capi ;;
  esac
}

git -C "$repo" check-ignore -q "$repo/build-apple/probe" || { echo 'build-apple must be gitignored' >&2; exit 1; }
git -C "$repo" check-ignore -q "$repo/build-ios/probe" || { echo 'build-ios must be gitignored' >&2; exit 1; }

# CI checks vcpkg out separately; local checkouts commonly live at ~/vcpkg.
# The first positional argument or VCPKG_ROOT selects an explicit toolchain.
vcpkg_root="${vcpkg_argument:-${VCPKG_ROOT:-}}"
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

out="$repo/build/xcframework"
mkdir -p "$out/headers"
cp "$repo/modules/capi/include/hyperdr/hyperdr.h" "$out/headers/"
cp "$repo/apps/apple/Packages/HyperDREngine/Modules/module.modulemap" "$out/headers/"

# One relocatable object per slice, read from the actual link line so the
# archive follows the real static dependency closure without maintaining a
# second C++ graph here.
combine_slice() {
  local slice="$1" work="$2"
  python3 - "$work" "$out/$slice" "$(slice_link_platform "$slice")" "$(slice_closure_target "$slice")" <<'PY'
import pathlib, shlex, subprocess, sys
work, out, platform, target = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3], sys.argv[4]
out.mkdir(parents=True, exist_ok=True)
commands = subprocess.check_output(['ninja', '-C', str(work), '-t', 'commands', target], text=True)
line = next(line for line in commands.splitlines()
            if ' -o HyperDR ' in line or ' -o libhyperdr.dylib ' in line)
tokens = shlex.split(line)
archives = [work / 'libhyperdr.a']
# Only archives are collected, so a dependency that became a dylib would be
# dropped from the xcframework silently and fail later, in the app's link.
dylibs = [token for token in tokens
          if '.dylib' in token and not token.startswith(('/usr/lib/', '/System/'))]
if dylibs:
    sys.exit('The CLI link line names non-system dynamic libraries, which the xcframework '
             'cannot carry: ' + ', '.join(dylibs))
for token in tokens:
    if token.endswith('.a'):
        path = pathlib.Path(token)
        path = path if path.is_absolute() else work / path
        if path not in archives: archives.append(path)

def is_static_archive(path):
    try:
        with open(path, 'rb') as stream:
            return stream.read(8) == b'!<arch>\n'
    except OSError:
        return False

# vcpkg builds libtiff as a static framework on iOS, so it appears as
# `-framework tiff` beside `-F<lib>`, not as a .a. Pull the framework's binary
# in when it really is an archive; SDK frameworks only ship an .tbd stub and are
# left for the app's own link (the Swift package declares them).
search = []
for index, token in enumerate(tokens):
    if token == '-F' and index + 1 < len(tokens):
        search.append(pathlib.Path(tokens[index + 1]))
    elif token.startswith('-F') and len(token) > 2:
        search.append(pathlib.Path(token[2:]))
for index, token in enumerate(tokens):
    if token != '-framework' or index + 1 >= len(tokens):
        continue
    name = tokens[index + 1]
    for directory in search:
        binary = directory / f'{name}.framework' / name
        if is_static_archive(binary) and binary not in archives:
            archives.append(binary)
            break
# CMake enables Release LTO. Materialize bitcode before packaging: Xcode's
# xcframework scanner cannot infer an architecture from LLVM-only members.
subprocess.run(['xcrun', 'ld', '-r', '-arch', 'arm64', '-platform_version', platform, '26.0', '26.0',
                '-all_load', *map(str, archives), '-o', str(out / 'HyperDREngineCore.o')], check=True)
subprocess.run(['xcrun', 'libtool', '-static', '-o', str(out / 'libHyperDREngineCore.a'),
                str(out / 'HyperDREngineCore.o')], check=True)
PY
}

# An earlier build staged dylibs here; the archive never needs them.
rm -rf "$out/Runtime"
libraries=()
for slice in "${slices[@]}"; do
  work="$(slice_build_dir "$slice")"
  echo "== $slice: configuring $(slice_preset "$slice") in $work"
  cmake --preset "$(slice_preset "$slice")" -S "$repo" -B "$work" -DHYPERDR_BUILD_TESTS=OFF \
    -DCMAKE_TOOLCHAIN_FILE="$toolchain"
  if [[ "$slice" == macos ]]; then
    cmake --build "$work" --target hyperdr_capi_static HyperDR
  else
    # The iOS slices are a library for the app: no CLI, and no ncnn.
    cmake --build "$work" --target hyperdr_capi_static
  fi
  echo "== $slice: combining the static closure"
  combine_slice "$slice" "$work"
  libraries+=(-library "$out/$slice/libHyperDREngineCore.a" -headers "$out/headers")
done

rm -rf "$out/HyperDREngineCore.xcframework"
xcodebuild -create-xcframework "${libraries[@]}" -output "$out/HyperDREngineCore.xcframework"
mkdir -p "$repo/apps/apple/Packages/HyperDREngine/Artifacts"
ln -sfn ../../../../../build/xcframework/HyperDREngineCore.xcframework "$repo/apps/apple/Packages/HyperDREngine/Artifacts/HyperDREngineCore.xcframework"
if [[ "$platforms" == macos ]]; then
  "$repo/build-apple/HyperDR" schema > "$out/schema-cli.json"
fi
echo "Built ${slices[*]}: $out/HyperDREngineCore.xcframework"
