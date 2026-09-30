#!/bin/bash
# Checks a built NoBlast.app: contents, signature, and that the models really load.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="${1:-$(dirname "$SCRIPT_DIR")/dist/NoBlast.app}"
fail() { echo "FAIL: $*" >&2; exit 1; }

[ -d "$APP" ] || fail "no app at $APP"
for path in \
    Contents/MacOS/NoBlast \
    Contents/Info.plist \
    Contents/Resources/NoBlast_NoBlastCore.bundle \
    Contents/Resources/Animations/unlockstatic.png \
    Contents/Resources/Animations/unlockanimation.mp4 \
    Contents/Resources/Animations/unsuccessfulunlockanimation.mp4 \
    Contents/Resources/THIRD_PARTY_NOTICES.md \
    Contents/Frameworks/Sparkle.framework \
    Contents/Library/LaunchAgents/io.oshoez.noblast.agent.plist
do
    [ -e "$APP/$path" ] || fail "missing $path"
done
# SwiftPM's native build system produces a flat resource bundle; the Xcode build
# system (used on some dev machines) wraps it in Contents/Resources. Find either way.
for model in ArcFace AntiSpoof; do
    find "$APP/Contents/Resources/NoBlast_NoBlastCore.bundle" -name "$model.mlmodelc" -print -quit | grep -q . \
        || fail "missing $model.mlmodelc in NoBlast_NoBlastCore.bundle"
done

codesign --verify --deep --strict "$APP" || fail "signature does not verify"
[ "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$APP/Contents/Info.plist")" = "true" ] || fail "LSUIElement is not set (the app would show a Dock icon)"
/usr/libexec/PlistBuddy -c 'Print :NSCameraUsageDescription' "$APP/Contents/Info.plist" >/dev/null || fail "no camera usage description"


"$APP/Contents/MacOS/NoBlast" --self-check || fail "self-check failed"

echo "OK: $APP"
