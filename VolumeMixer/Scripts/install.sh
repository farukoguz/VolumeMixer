#!/bin/bash
# Installs VolumeMixer.app on this Mac.
#
# The interesting part is not the copy. What makes an app run on somebody else's
# Mac is decided by three things the copy cannot fix, so this script checks each
# one and says plainly what is still missing rather than leaving a user to
# discover it as a silent failure:
#
#   1. the architecture -- the bundle must contain the CPU this Mac has
#   2. trust -- the code signature must be one this Mac accepts
#   3. permission -- Screen & System Audio Recording is granted per Mac, per
#      user, by hand. No installer can do it, and skipping it is why the app
#      appears to do nothing at all.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILT="$ROOT/build/VolumeMixer.app"

TARGET="/Applications"
if [ ! -w "$TARGET" ]; then
    TARGET="$HOME/Applications"
    echo "==> /Applications is not writable, installing to $TARGET instead"
    mkdir -p "$TARGET"
fi

if [ ! -d "$BUILT" ]; then
    echo "==> no bundle yet, building it first"
    "$ROOT/Scripts/build-app.sh"
fi

echo "==> installing to $TARGET/VolumeMixer.app"
if [ -d "$TARGET/VolumeMixer.app" ]; then
    echo "    replacing the existing copy"
fi
rm -rf "$TARGET/VolumeMixer.app"
cp -R "$BUILT" "$TARGET/VolumeMixer.app"
# An app that arrived by AirDrop, Mail or a zip carries a quarantine flag, and
# Gatekeeper then refuses it before anything in it gets a chance to run.
if xattr -p com.apple.quarantine "$TARGET/VolumeMixer.app" >/dev/null 2>&1; then
    xattr -dr com.apple.quarantine "$TARGET/VolumeMixer.app"
    echo "    removed the quarantine flag"
fi

APP="$TARGET/VolumeMixer.app"

echo "==> checking it can actually run here"
if ! lipo -archs "$APP/Contents/MacOS/VolumeMixer" 2>/dev/null | grep -qw "$(uname -m)"; then
    echo "!! FATAL: the bundle has no $(uname -m) slice; it cannot run on this Mac." >&2
    exit 1
fi
if ! codesign --verify --deep --strict "$APP" 2>/dev/null; then
    echo "!! FATAL: the signature does not verify on this Mac." >&2
    exit 1
fi

# TeamIdentifier is present only when a real certificate was used, which makes it
# the reliable signal here: codesign does not always print Authority lines, so
# parsing those would report an honestly signed app as ad-hoc.
SIGNING="$(codesign -dv "$APP" 2>&1)"
TEAM="$(printf '%s\n' "$SIGNING" | sed -nE 's/^TeamIdentifier=//p' | head -1)"
echo "    architectures:  $(lipo -archs "$APP/Contents/MacOS/VolumeMixer")"
if [ -n "$TEAM" ]; then
    echo "    signed:         yes, Team $TEAM"
else
    echo "    signed:         AD-HOC -- macOS will not grant Screen & System Audio"
    echo "                    Recording to this build, so gain cannot be measured."
fi

cat <<EOF

==> installed at $APP

Two things are left, and neither can be done by a script.

1. If macOS refuses to open it ("cannot be opened because the developer cannot
   be verified"), that Mac does not trust the signing certificate. Either
   right-click the app and choose Open once, or install the certificate into
   that Mac's keychain. A Development certificate is only trusted where it is
   installed, so for anybody else's Mac the real answer is Developer ID
   signing plus notarisation, which needs a paid Apple Developer account.

2. Grant the permission, on this Mac, in System Settings > Privacy & Security >
   Screen & System Audio Recording. macOS gates it per Mac and per user, so it
   has to be granted on every machine separately. Without it the app cannot
   read any audio: the taps come up empty and every slider does nothing, with
   no error anywhere.

Then launch it. If the permission alert appears, "Try Again" picks the grant up
without a relaunch.
EOF