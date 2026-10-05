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
    echo "    signed:         ad-hoc"
fi

cat <<EOF

==> installed at $APP

Two things are left, and neither can be done by a script.

1. FIRST LAUNCH -- macOS refuses to open a build it cannot attribute to a
   trusted developer:

       "Volume Mixer cannot be opened because the developer cannot be verified"

   This is expected, and it is not a problem to fix. Right-click (or
   Control-click) Volume Mixer in Finder, choose Open, then confirm. macOS
   remembers that decision for the app, so this is a one-time step per Mac. If
   the Open button is greyed out, choose "Open anyway" in the same dialog.

   Removing that step entirely needs a Developer ID signature plus Apple
   notarisation, which requires a paid Apple Developer Program membership.

2. GRANT THE PERMISSION -- System Settings > Privacy & Security > Screen &
   System Audio Recording, then add Volume Mixer. macOS requires this per Mac
   and per user, and no installer can do it.

   Without it the app still launches and still lists whatever is playing, but
   it cannot read any audio: the taps come up empty, every slider does nothing,
   and no error is shown anywhere. That silence is the entire failure mode, so
   if a slider does nothing, check this before anything else.

   One wrinkle specific to ad-hoc builds: the grant is tied to that exact build,
   so a rebuild means granting it again. A signed build's grant survives a
   rebuild, which is the practical reason to sign once a certificate exists.

Then launch it. If the permission alert appears, "Try Again" picks up the grant
without a relaunch.
EOF