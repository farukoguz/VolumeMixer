#!/bin/bash
# Packages the built app into a zip for sharing with someone else.
#
# This is the only distribution path available without a paid Apple Developer
# Program membership. A Developer ID signature plus notarisation would let a
# user drag the app into Applications and launch it; without them macOS refuses
# to open an unattributable build, so the recipient has to right-click and
# choose Open once. `Scripts/package.sh` cannot change that, and pretending
# otherwise here would only move the failure to the user's first launch.
#
# What this does do is make the manual part small and identical for everyone:
# one zip, one README, one place for the two steps they have to do by hand.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILT="$ROOT/build/VolumeMixer.app"
OUT="$ROOT/build/dist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$BUILT/Contents/Info.plist" 2>/dev/null || echo "0.0.0")"
ZIP="$OUT/VolumeMixer-$VERSION.zip"

if [ ! -d "$BUILT" ]; then
    echo "!! nothing to package: $BUILT does not exist. Run Scripts/build-app.sh first." >&2
    exit 1
fi

# Package the bundle the build just produced, not whatever happens to be sitting
# in /Applications. Those differ more often than you would think -- a reinstall
# on this Mac leaves a stale copy behind, and that copy is then the one shipped.
echo "==> signing state of the build being packaged"
if codesign -dv "$BUILT" 2>&1 | grep -q '^TeamIdentifier='; then
    echo "    signed with a certificate (Team $(codesign -dv "$BUILT" 2>&1 |
        sed -nE 's/^TeamIdentifier=//p' | head -1))"
else
    echo "    ad-hoc -- recipients must right-click > Open once"
fi

# Only this script's own artefacts. Wiping the whole directory used to be safe
# when it was the only thing writing here; now that make-dmg.sh shares it, doing
# that would silently delete a DMG someone had already built and was about to
# upload.
mkdir -p "$OUT"
rm -f "$ZIP" "$OUT/READ ME FIRST.txt"

# ditto, not zip: it is the only archiver that reliably preserves the symlinks
# and extended attributes inside a macOS bundle. A plain `zip` occasionally
# flattens them, producing an app that builds and signs fine but misbehaves once
# it is running from /Applications.
echo "==> packaging $ZIP"
ditto -c -k --sequesterRsrc --keepParent "$BUILT" "$ZIP"

cat > "$OUT/READ ME FIRST.txt" <<EOF
VolumeMixer $VERSION
===================

This build is not signed with Developer ID and is not notarised, so macOS needs
a moment of help the first time. Two steps, once per Mac.

1. Unzip it, then drag VolumeMixer.app to Applications.

2. Launch it once by hand. macOS will say "cannot be opened because the
   developer cannot be verified". Right-click (or Control-click) Volume Mixer in
   Finder, choose Open, and confirm. If the Open button is greyed out, choose
   "Open anyway" in the same dialog.

   macOS remembers this per app, so it is only ever needed once.

3. Grant the permission: System Settings > Privacy & Security > Screen &
   System Audio Recording, then add Volume Mixer.

   This step is required and no installer can perform it. Without it Volume
   Mixer opens and lists whatever is playing, but every slider does nothing and
   no error appears anywhere. If a slider has no effect, this is the reason.

Uninstalling is just dragging the app back to the Trash. The permission entry
can stay; it does nothing without the app.
EOF

echo
echo "==> done"
echo "    $ZIP"
echo "    $(du -h "$ZIP" | cut -f1)"
echo
echo "Send that zip together with READ ME FIRST.txt."
