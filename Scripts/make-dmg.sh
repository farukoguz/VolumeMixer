#!/bin/bash
# Builds VolumeMixer-<version>.dmg -- the installer a release page offers.
#
# A .dmg rather than a .zip because the drag-to-Applications gesture is the whole
# point. A zip has to be unzipped, which puts a folder in front of the user and
# gives them somewhere to make a mistake; a mounted disk image shows the app next
# to an Applications shortcut, and dropping one on the other is the install.
#
# Nothing is scripted inside the image. A DMG cannot copy the app anywhere by
# itself: a double-clicking app that quietly installed itself would be malware's
# favourite trick, and Gatekeeper's whole job is to refuse to run code the user
# did not choose to run. So the user drags, and the only thing this script adds is
# the target to drop onto.
#
# What it does automate is the part that silently goes wrong: an unsigned bundle
# arriving through a browser carries a quarantine flag, and the first drag then
# fails with "cannot be opened because the developer cannot be verified" *after*
# the user has already moved it. Quarantine is set by whatever downloads a file,
# not by anything in the image, so it cannot be cleared here -- only avoided, by
# the right-click step the README explains.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/VolumeMixer.app"
OUT="$ROOT/build/dist"

STAGE="$(mktemp -d)"
DMG="$OUT/VolumeMixer-1.0.dmg"
MOUNT_NAME="Volume Mixer"

if [ ! -d "$APP" ]; then
    echo "!! nothing to package: $APP does not exist. Run Scripts/build-app.sh first." >&2
    exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$APP/Contents/Info.plist")"
DMG="$OUT/VolumeMixer-$VERSION.dmg"

if codesign -dv "$APP" 2>&1 | grep -q '^TeamIdentifier='; then
    SIGNING="signed, Team $(codesign -dv "$APP" 2>&1 |
        sed -nE 's/^TeamIdentifier=//p' | head -1)"
else
    SIGNING="ad-hoc"
fi

echo "==> packaging $VERSION ($SIGNING)"

# Fail here rather than ship an image that mounts to nothing.
codesign --verify --deep --strict "$APP" || {
    echo "!! the signature does not verify; refusing to package it" >&2
    exit 1
}

rm -f "$DMG"
mkdir -p "$OUT"
mkdir -p "$STAGE"

# ditto, not cp: it is the only archiver/copier that reliably preserves a bundle's
# symlinks and resource forks. The executable bit and the code signature both
# depend on arriving intact.
ditto "$APP" "$STAGE/VolumeMixer.app"

# The drop target. A symlink to the real folder, not a copy of it: this is a
# Finder navigation shortcut, and the app must land in the user's actual
# /Applications rather than a duplicate inside the read-only image.
ln -s /Applications "$STAGE/Applications"

# Set the window layout so the two icons are already side by side. Cosmetic, and
# SetFile is absent on a system without developer tools -- the image still mounts
# and the drag still works without it, so failure here is ignored.
if command -v SetFile >/dev/null 2>&1; then
    SetFile -a C "$STAGE" 2>/dev/null || true
fi

# Two steps, because hdiutil cannot compress while creating from a folder: the
# first pass makes a read-write image, the second compresses it. Doing it in one
# call with -format UDZO fails outright rather than falling back.
#
# -srcfolder rather than -size and -fs from a directory: it copies the staged tree
# with the bits a bundle needs (executable permissions, resource forks) instead
# of imaging a filesystem underneath it.
RW="$STAGE.dmg"
hdiutil create \
    -volname "$MOUNT_NAME" \
    -fs HFS+ \
    -format UDRW \
    -srcfolder "$STAGE" \
    -ov \
    "$RW" >/dev/null

# UDZO is zlib. UDBZ is bzip2 and larger for the same content; every macOS can
# read either, so there is nothing to trade away by picking the smaller one.
hdiutil convert "$RW" -format UDZO -o "$DMG" >/dev/null
rm -f "$RW"

# Read it back and confirm the app inside is intact. A dmg that verifies but whose
# bundle does not is the worst outcome: it looks fine until the user has dragged.
MOUNTED="$(mktemp -d)"
hdiutil attach "$DMG" -mountpoint "$MOUNTED" -nobrowse -quiet
if ! codesign --verify --deep --strict "$MOUNTED/VolumeMixer.app" 2>/dev/null; then
    hdiutil detach "$MOUNTED" -quiet
    echo "!! the app inside the image does not verify; refusing to publish it" >&2
    exit 1
fi
hdiutil detach "$MOUNTED" -quiet
rm -rf "$MOUNTED"

echo "==> done"
echo "    $DMG"
echo "    $(du -h "$DMG" | cut -f1)"
echo
echo "Publish it with:"
echo "    git tag -a v$VERSION -m 'Version $VERSION'"
echo "    git push origin v$VERSION"
echo "    # then attach build/dist/VolumeMixer-$VERSION.dmg to the release on GitHub"

rm -rf "$STAGE"
