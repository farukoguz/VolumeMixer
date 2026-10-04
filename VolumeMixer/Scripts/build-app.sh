#!/bin/bash
# Assembles VolumeMixer.app from the SwiftPM build.
#
# An .app bundle is mandatory here, not cosmetic: macOS gates process taps on the
# kTCCServiceAudioCapture TCC service, which is keyed on the bundle's Info.plist
# and code signature. Running the bare SwiftPM binary produces a *silent* tap --
# every Core Audio call returns noErr while the buffers are all zeros.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
APP="$ROOT/build/VolumeMixer.app"

# Uses whatever toolchain swift build resolves (Command Line Tools is enough --
# we only need the SDK headers and ad-hoc codesign, not xcodebuild).

echo "==> swift build -c $CONFIG"
cd "$ROOT"
swift build -c "$CONFIG"

BIN="$(swift build -c "$CONFIG" --show-bin-path)/VolumeMixer"
[ -f "$BIN" ] || { echo "!! binary not found at $BIN"; exit 1; }

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/VolumeMixer"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# Copy anything else that lives beside Info.plist (an app icon, a preset) into
# Contents/Resources. The directory is deliberately not created unconditionally:
# an empty Contents/Resources makes codesign record a signature that claims
# resources are present, and the bundle then fails its own verification with
# "code has no resources but signature indicates they must be present".
shopt -s nullglob
resources=("$ROOT/Resources"/*)
shopt -u nullglob
for item in "${resources[@]}"; do
    case "$(basename "$item")" in
        Info.plist) continue ;;
    esac
    mkdir -p "$APP/Contents/Resources"
    cp -R "$item" "$APP/Contents/Resources/"
done
rmdir "$APP/Contents/Resources" 2>/dev/null || true

# Verify the privacy key actually made it into the compiled bundle. TCC denial is
# silent, so a missing key here is the single most important thing to catch.
if ! plutil -extract NSAudioCaptureUsageDescription raw "$APP/Contents/Info.plist" >/dev/null 2>&1; then
  echo "!! FATAL: NSAudioCaptureUsageDescription missing from bundle -- taps would be silently muted"
  exit 1
fi
echo "    NSAudioCaptureUsageDescription present OK"

# Prefer a real signing identity, because macOS will not grant Screen & System
# Audio Recording to an ad-hoc build: taps are created, every buffer is zero, and
# nothing anywhere reports a refusal. An app with no Team ID is anonymous as far
# as TCC is concerned, so there is nothing for the user to grant it in.
SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -E '"(Apple Development|Developer ID Application|Mac App Distribution)' \
    | head -1 | sed -E 's/^[^"]*"(.*)"$/\1/')"

if [ -n "$SIGN_IDENTITY" ]; then
    echo "==> codesigning ($SIGN_IDENTITY)"
    codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$APP" 2>&1 | sed 's/^/    /'
else
    echo "==> codesigning (ad-hoc, no identity found)"
    echo "    !! Screen & System Audio Recording cannot be granted to this build."
    echo "    !! Add a signing identity, or gain will stay unverifiable."
    codesign --force --sign - --timestamp=none "$APP" 2>&1 | sed 's/^/    /'
fi
codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/    /'

echo "==> done: $APP"
echo "    run:  open '$APP'"