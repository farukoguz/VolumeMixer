#!/bin/bash
# Assembles VolumeMixer.app from the SwiftPM build.
#
# An .app bundle is mandatory here, not cosmetic: macOS gates process taps on the
# kTCCServiceAudioCapture TCC service, which is keyed on the bundle's Info.plist
# and code signature. Running the bare SwiftPM binary produces a *silent* tap --
# every Core Audio call returns noErr while the buffers are all zeros.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/VolumeMixer.app"

# Arguments are parsed before anything uses CONFIG. Doing this further down looks
# tidier but is wrong: the build loop below runs first and would be handed
# "--ad-hoc" as a configuration name.
#
#   --ad-hoc   sign ad-hoc, ignoring any certificate in the keychain
#   <name>     build configuration, defaulting to release
SIGN_AD_HOC=""
while [ $# -gt 0 ]; do
    case "$1" in
        --ad-hoc) SIGN_AD_HOC=1 ;;
        -h|--help)
            sed -n '2,7p' "$0" | sed 's/^#\{1,1\} \{0,1\}//'
            echo
            echo "Usage: $0 [--ad-hoc] [configuration]"
            exit 0
            ;;
        *) break ;;
    esac
    shift
done
CONFIG="${1:-release}"

# Uses whatever toolchain swift build resolves (Command Line Tools is enough --
# we only need the SDK headers and ad-hoc codesign, not xcodebuild).

cd "$ROOT"

# Built as one fat binary covering both Mac architectures, because the bundle
# gets copied to other machines and a single-architecture build simply will not
# launch on the other kind of Mac.
#
# The two slices are built separately rather than with `swift build --arch arm64
# --arch x86_64`, because the multi-architecture form is implemented in xcbuild,
# which ships with Xcode and not with the Command Line Tools. Building each and
# joining them needs neither.
ARCHS="${ARCHS:-arm64 x86_64}"
SLICES=()
FAILED=""
for arch in $ARCHS; do
    echo "==> swift build -c $CONFIG --arch $arch"
    if swift build -c "$CONFIG" --arch "$arch"; then
        slice="$(swift build -c "$CONFIG" --arch "$arch" --show-bin-path)/VolumeMixer"
        [ -f "$slice" ] && SLICES+=("$slice") || FAILED="$FAILED $arch"
    else
        FAILED="$FAILED $arch"
    fi
done

[ ${#SLICES[@]} -gt 0 ] || { echo "!! no architecture built successfully$FAILED" >&2; exit 1; }
[ -n "$FAILED" ] && echo "!! skipped architecture(s):$FAILED" >&2

BIN="$ROOT/build/.VolumeMixer-universal"
mkdir -p "$(dirname "$BIN")"
if [ ${#SLICES[@]} -eq 1 ]; then
    cp "${SLICES[0]}" "$BIN"
else
    lipo -create "${SLICES[@]}" -output "$BIN"
fi
echo "==> architectures: $(lipo -archs "$BIN")"

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
rm -f "$BIN"

# Verify the privacy keys actually made it into the compiled bundle. TCC denial is
# silent, so a missing key here is the single most important thing to catch.
#
# Both keys are required, and they are not interchangeable. `AudioHardwareCreate-
# ProcessTap` is gated by TCC under Screen & System Audio Recording, which macOS
# derives from NSScreenCaptureUsageDescription -- not from the Microphone prompt.
# With only the audio-capture key the app appears under Microphone, is granted
# there, and every tap still delivers zeros, because the service that governs
# process taps was never asked for.
for key in NSScreenCaptureUsageDescription NSAudioCaptureUsageDescription; do
    if ! plutil -extract "$key" raw "$APP/Contents/Info.plist" >/dev/null 2>&1; then
        echo "!! FATAL: $key missing from bundle -- taps would be silently muted"
        exit 1
    fi
    echo "    $key present OK"
done

# Which identity to sign with, in order of preference.
#
#   SIGN_IDENTITY=...  sign with exactly this identity
#   SIGN_AD_HOC=1      sign ad-hoc, ignoring any certificate in the keychain
#   (unset)            use the first codesigning identity found
#
# A real certificate is preferred, and a Development one is enough for a build
# that will only ever run on the machine that made it. Neither kind helps on
# somebody else's Mac: Gatekeeper refuses an Apple Development signature
# outright, so a user must right-click and choose Open once, every time.
#
# Ad-hoc is not a fallback that "loses" permissions -- it is genuinely
# grantable. The cost is subtler and worth stating plainly: macOS records a TCC
# grant against the exact code it saw, so the grant does not survive a rebuild.
# Change one byte, and the user's screen-recording permission has to be given
# again. That is fine for someone iterating on the build, and miserable for
# someone handed a download, which is why signing still wins by default.
#
# `--ad-hoc` is provided for the case that matters most: a contributor with no
# certificate at all. Without it such a build still works locally, but only by
# accident of the keychain happening to hold something usable.
if [ -n "${SIGN_AD_HOC:-}" ]; then
    SIGN_IDENTITY=""
else
    SIGN_IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -E '"(Apple Development|Developer ID Application|Mac App Distribution)' \
        | head -1 | sed -E 's/^[^"]*"(.*)"$/\1/')}"
fi

if [ -n "$SIGN_IDENTITY" ]; then
    echo "==> codesigning ($SIGN_IDENTITY)"
    # errSecInternalComponent here does not mean the bundle is malformed: the
    # bundle signs ad-hoc without complaint and the same key signs a plain file
    # without complaint. It means macOS wants to ask whether codesign may use the
    # private key, and has no way to ask -- a non-interactive session, a script,
    # an IDE build. Granting that trust once turns this into a silent success.
    sign_err="$(mktemp)"
    # --options runtime is the hardened runtime. Nothing needs it for a local
    # build, but notarisation refuses to accept a bundle without it, and
    # notarisation is what lets this run on a Mac that does not already know the
    # signing certificate.
    if ! codesign --force --options runtime --sign "$SIGN_IDENTITY" --timestamp=none "$APP" 2>"$sign_err"; then
        sed 's/^/    /' "$sign_err"
        echo "!! FATAL: could not sign with $SIGN_IDENTITY." >&2
        if grep -q errSecInternalComponent "$sign_err"; then
            echo "   macOS is withholding permission to use the signing key and" >&2
            echo "   cannot prompt here. Grant it once, then build again:" >&2
            echo "       ./Scripts/setup-signing.sh" >&2
        fi
        rm -f "$sign_err"
        exit 1
    fi
    rm -f "$sign_err"
else
    echo "==> codesigning (ad-hoc)"
    echo "    Screen & System Audio Recording can be granted to this build."
    echo "    The grant is tied to this exact code, so a rebuild means granting it"
    echo "    again. Gatekeeper will also require right-click > Open the first time."
    codesign --force --sign - --timestamp=none "$APP" 2>&1 | sed 's/^/    /'
fi
codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/    /'

echo "==> done: $APP"
echo "    run:  open '$APP'"