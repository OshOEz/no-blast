#!/bin/bash
# Runs the tests with coverage and fails when a target's line coverage drops below its floor.
# Floors only go up, and only through an explicit PR. CameraCapture and LocalSystemAuth are left out:
# they need a camera and Touch ID, which CI doesn't have.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
swift test --enable-code-coverage
BIN="$(swift build --show-bin-path)"
PROFILE="$(dirname "$(swift test --show-codecov-path)")/default.profdata"
status=0

# SwiftPM's native build system links every test target into one combined
# *PackageTests.xctest bundle; the Xcode build system produces one bundle per
# target. Prefer the per-target bundle when it exists, else fall back to the
# combined one -- either way it contains the target's instrumented code.
test_binary() {
    local target="$1" bundle
    bundle="$(find "$BIN" -maxdepth 1 -name "${target}Tests.xctest" -print -quit)"
    [ -n "$bundle" ] || bundle="$(find "$BIN" -maxdepth 1 -name '*PackageTests.xctest' -print -quit)"
    echo "$bundle/Contents/MacOS/$(basename "$bundle" .xctest)"
}

check() {
    local target="$1" floor="$2" percent
    percent="$(xcrun llvm-cov report "$(test_binary "$target")" \
        -instr-profile "$PROFILE" -ignore-filename-regex '(CameraCapture|LocalSystemAuth)\.swift' "Sources/$target" \
        | awk '/^TOTAL/ { gsub("%", "", $10); print $10 }')"
    echo "$target line coverage: ${percent}% (floor ${floor}%)"
    if ! awk -v p="$percent" -v f="$floor" 'BEGIN { exit !(p >= f) }'; then
        echo "FAIL: $target is below its ${floor}% floor" >&2
        status=1
    fi
}

check NoBlastCore 88
check NoBlastEngine 77
exit "$status"
