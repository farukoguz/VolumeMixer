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
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/VolumeMixer"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# Verify the privacy key actually made it into the compiled bundle. TCC denial is
# silent, so a missing key here is the single most important thing to catch.
if ! plutil -extract NSAudioCaptureUsageDescription raw "$APP/Contents/Info.plist" >/dev/null 2>&1; then
  echo "!! FATAL: NSAudioCaptureUsageDescription missing from bundle -- taps would be silently muted"
  exit 1
fi
echo "    NSAudioCaptureUsageDescription present OK"

echo "==> codesigning (ad-hoc)"
codesign --force --sign - --timestamp=none "$APP" 2>&1 | sed 's/^/    /'
codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/    /'

echo "==> done: $APP"
echo "    run:  open '$APP'"