#!/bin/bash
# Run gate T2 on a local macOS machine instead of the hosted runner.
#
# Same steps, same frozen inputs, and same decision rule as
# .github/workflows/macos-display-t2.yml. The only additions are a preflight
# that fails before anything is compiled when the machine cannot satisfy the
# gate, and a zipped evidence bundle for carrying the result back.
#
# Usage:  bash tests/macos_t2/run_t2_local.sh [output-dir]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
OUTPUT="${1:-t2-output}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/hyperdr-t2.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail() {
  printf '\nT2 preflight failed: %s\n' "$1" >&2
  exit 2
}

printf '== T2 preflight ==\n'

[ "$(uname -s)" = "Darwin" ] || fail "this script must run on macOS, not $(uname -s)"

PRODUCT_VERSION="$(sw_vers -productVersion)"
MAJOR="${PRODUCT_VERSION%%.*}"
if [ "$MAJOR" -lt 15 ]; then
  fail "macOS $PRODUCT_VERSION is too old; the ISO gain-map decode path this gate
adjudicates requires macOS 15 or newer"
fi

command -v xcrun >/dev/null 2>&1 || fail "xcrun is missing; install the Xcode
command line tools with: xcode-select --install"
xcrun --find swiftc >/dev/null 2>&1 || fail "swiftc is missing; install the Xcode
command line tools with: xcode-select --install"
xcrun --find clang++ >/dev/null 2>&1 || fail "clang++ is missing; install the Xcode
command line tools with: xcode-select --install"
command -v python3 >/dev/null 2>&1 || fail "python3 is missing; it ships with the
Xcode command line tools"

for required in \
  tests/macos_t2/CoreImageT2.swift \
  tests/macos_t2/cpp_reference.cpp \
  tests/macos_t2/fixture_manifest.json \
  tests/macos_t2/fixture_spec.json \
  tests/macos_t2/fixtures/gamma-1-control.heic \
  tests/macos_t2/fixtures/gamma-2-probe.heic \
  modules/gainmap/src/reconstruct.cpp \
  modules/container/src/iso_gain_map.cpp
do
  [ -f "$required" ] || fail "missing $required; run this from a complete checkout
or from the full transfer bundle, not from the tests/macos_t2 directory alone"
done

printf 'macOS %s (%s), toolchain present\n' "$PRODUCT_VERSION" "$(uname -m)"

mkdir -p "$OUTPUT"

printf '\n== Record the toolchain ==\n'
{
  sw_vers
  uname -m
  xcodebuild -version 2>/dev/null || printf 'xcodebuild: not available (command line tools only)\n'
  xcrun swiftc --version
  xcrun clang++ --version | head -n 1
  date -u +'run_utc=%Y-%m-%dT%H:%M:%SZ'
} | tee "$OUTPUT/toolchain.txt"

printf '\n== Verify the frozen only-gamma fixture pair ==\n'
python3 tests/macos_t2/generate_fixtures.py verify

printf '\n== Compile the independent Core Image harness ==\n'
xcrun swiftc -O tests/macos_t2/CoreImageT2.swift \
  -framework CoreImage -framework CoreGraphics -framework ImageIO \
  -o "$WORK/core-image-t2"

printf '\n== Compile the ImageIO diagnostic ==\n'
xcrun swiftc -O tests/macos_t2/diagnose_imageio.swift \
  -framework CoreImage -framework CoreGraphics -framework ImageIO \
  -o "$WORK/imageio-diagnostic"

printf '\n== Compile the checked-in C++ reconstruction reference ==\n'
xcrun clang++ -std=c++20 -O2 -pthread \
  -I modules/gainmap/include \
  -I modules/container/include \
  -I modules/foundation/include \
  -I modules/image/include \
  tests/macos_t2/cpp_reference.cpp \
  modules/gainmap/src/reconstruct.cpp \
  modules/container/src/iso_gain_map.cpp \
  -o "$WORK/cpp-t2-reference"

printf '\n== Ask ImageIO what it sees in each file ==\n'
# Four kinds of file, so that an absence is attributable: the frozen fixtures,
# the pre-repair pair that macOS refused on 2026-08-09, and third-party captures
# written by Apple and by Adobe. Missing third-party references are called out
# loudly, because without them a refusal cannot be attributed at all.
# Positional parameters rather than an array: /bin/bash on macOS is 3.2, where an
# empty array expanded under `set -u` aborts the script.
set --
for candidate in tests/macos_t2/fixtures-prerepair/* tests/macos_t2/probes/* tests/macos_t2/reference/*; do
  case "$candidate" in
    *.heic|*.HEIC|*.heif|*.HEIF|*.jpg|*.JPG|*.jpeg|*.JPEG)
      [ -f "$candidate" ] && set -- "$@" "$candidate" ;;
  esac
done
if [ "$#" -eq 0 ]; then
  printf 'WARNING: no reference or pre-repair file found; a gain-map absence will\n'
  printf 'not be attributable.\n'
fi
"$WORK/imageio-diagnostic" \
  tests/macos_t2/fixtures/gamma-1-control.heic \
  tests/macos_t2/fixtures/gamma-2-probe.heic \
  "$@" 2>&1 | tee "$OUTPUT/imageio-diagnostic.txt"

printf '\n== Render two distinct EDR headrooms with ImageIO and Core Image ==\n'
# Non-fatal on purpose: a Core Image refusal is itself evidence, and the
# diagnostic above plus the toolchain record must still reach the bundle.
set +e
"$WORK/core-image-t2" \
  tests/macos_t2/fixture_manifest.json \
  tests/macos_t2/fixture_spec.json \
  "$OUTPUT" \
  "$OUTPUT/core-image-report.json"
RENDER_STATUS=$?
set -e

VALIDATOR_STATUS=0
if [ "$RENDER_STATUS" -ne 0 ]; then
  printf '\nCore Image did not render the pair; skipping the C++ comparison and the\n'
  printf 'decision rule, which have nothing to compare against. Read\n'
  printf '%s/imageio-diagnostic.txt for what Apple exposed.\n' "$OUTPUT"
  VALIDATOR_STATUS="$RENDER_STATUS"
else
  printf '\n== Render the same decoded inputs with the C++ implementation ==\n'
  "$WORK/cpp-t2-reference" \
    "$OUTPUT/gamma-1-control-decoded-input.bin" \
    "$OUTPUT/gamma-1-control-cpp.json" \
    1 0.5 1.0 1.5 gamma-1-control
  "$WORK/cpp-t2-reference" \
    "$OUTPUT/gamma-2-probe-decoded-input.bin" \
    "$OUTPUT/gamma-2-probe-cpp.json" \
    2 0.5 1.0 1.5 gamma-2-probe

  printf '\n== Apply the frozen pixelwise decision rule ==\n'
  set +e
  python3 tests/macos_t2/validate_t2.py \
    --spec tests/macos_t2/fixture_spec.json \
    --manifest tests/macos_t2/fixture_manifest.json \
    --core-image "$OUTPUT/core-image-report.json" \
    --cpp "$OUTPUT/gamma-1-control-cpp.json" \
    --cpp "$OUTPUT/gamma-2-probe-cpp.json" \
    --schema tests/macos_t2/report.schema.json \
    --output "$OUTPUT/t2-report.json"
  VALIDATOR_STATUS=$?
  set -e
fi

BUNDLE="$OUTPUT/../t2-evidence-$(date -u +%Y%m%dT%H%M%SZ).zip"
ditto -c -k --sequesterRsrc "$OUTPUT" "$BUNDLE"

printf '\n== Result ==\n'
printf 'diagnostic: %s\n' "$OUTPUT/imageio-diagnostic.txt"
printf 'evidence:   %s\n' "$BUNDLE"
if [ "$RENDER_STATUS" -ne 0 ]; then
  printf 'status:     Core Image refused the fixtures; T2 did not adjudicate anything.\n'
  printf 'That is a third refusal, so the probe matrix is the result. In\n'
  printf 'imageio-diagnostic.txt read the ISOGainMap line of each path:\n'
  printf '  probes/normal-512x384-repaired  PRESENT -> the ordinary path is fine and the 8x4 fixture is the problem\n'
  printf '  probes/normal-512x384-repaired  absent  -> the writer is wrong beyond both repairs\n'
  printf '  fixtures-prerepair and tiny-8x4-auxrepair-only must stay absent; if either turned\n'
  printf '  PRESENT, something other than the file changed and the run is not comparable\n'
  printf '  reference/ must stay PRESENT for both captures, or the diagnostic itself is suspect\n'
elif [ "$VALIDATOR_STATUS" -eq 0 ]; then
  printf 'report:     %s\n' "$OUTPUT/t2-report.json"
  printf 'status:     pass — Core Image matches code-domain interpolation at every registered headroom\n'
else
  printf 'report:     %s\n' "$OUTPUT/t2-report.json"
  printf 'status:     FAIL — read the "failures" array in t2-report.json\n'
fi
printf 'Carry the whole evidence bundle back either way; a refusal is a result, not a lost run.\n'
exit "$VALIDATOR_STATUS"
