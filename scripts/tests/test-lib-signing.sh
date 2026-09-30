#!/bin/bash
# Signs a copy of a system binary with sign_code and checks the result verifies and
# carries the requested identifier in its designated requirement.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091 # sourced from a computed path; lib-signing.sh is one directory up
source "$SCRIPT_DIR/../lib-signing.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp /bin/echo "$WORK/sample"

sign_code "$WORK/sample" com.noblast.test >/dev/null 2>&1
codesign --verify --strict "$WORK/sample"
requirement="$(codesign -dr - "$WORK/sample" 2>&1)"
echo "$requirement" | grep -qF 'identifier "com.noblast.test"' || { echo "FAIL: requirement lacks identifier: $requirement" >&2; exit 1; }

if signing_identity_available; then
    echo "$requirement" | grep -q "certificate" || { echo "FAIL: identity present but requirement has no certificate" >&2; exit 1; }
    echo "PASS (self-signed identity)"
else
    echo "PASS (ad-hoc fallback)"
fi
