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

check() {
    local target="$1" floor="$2" percent
    percent="$(xcrun llvm-cov report "$BIN/${target}Tests.xctest/Contents/MacOS/${target}Tests" \
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
