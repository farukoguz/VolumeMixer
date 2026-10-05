#!/bin/bash
# One-time signing setup, and the only step that needs your login password.
#
# The private key for a development certificate lives in the login keychain, and
# macOS protects each key with its own access list. Until codesign is trusted for
# that key, every build raises a dialog asking whether it may use it, and every
# build pauses until somebody types a password. This grants codesign access once,
# so `Scripts/build-app.sh` afterwards signs without asking anything.
#
# Nothing here is needed per build, and nothing here is stored: the password is
# read with echo off, used for one command, and discarded. It is not written to
# shell history, and it is not an argument that would end up in `ps` output.
set -euo pipefail

KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
# apple-tool and apple cover Apple's own tools; codesign is named explicitly
# because that is the tool that signs the app bundle.
PARTITIONS="apple-tool:,apple:,codesign:"

identity() {
    security find-identity -v -p codesigning 2>/dev/null \
        | grep -E '"(Apple Development|Developer ID Application|Mac App Distribution)' \
        | head -1 | sed -E 's/^[^"]*"(.*)"$/\1/'
}

IDENTITY="$(identity || true)"

if [ -z "$IDENTITY" ]; then
    echo "!! No signing identity in the keychain."
    echo
    echo "   With no identity the app can only be signed ad-hoc, and macOS will"
    echo "   not grant Screen & System Audio Recording to it, so gain cannot be"
    echo "   measured or verified. To fix that, either:"
    echo
    echo "   - export a .p12 from XCode > Settings > Accounts > Manage Certificates, then"
    echo "     security import your-cert.p12 -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign"
    echo "   - or create a free Apple Developer account and generate a certificate there."
    exit 1
fi

echo "==> identity: $IDENTITY"
echo "==> keychain: $KEYCHAIN"

if ! security show-keychain-info "$KEYCHAIN" >/dev/null 2>&1; then
    echo "!! keychain is locked; unlock it in Keychain Access first" >&2
    exit 1
fi

# There is deliberately no "is it already trusted?" check here. The trust is
# stored as a partition list that `security dump-keychain` does not print, so any
# such check either always says no and nags you for the password again, or says
# yes when the prompt is still going to appear. Setting the list is idempotent,
# so running it when it is already set costs one password entry and settles the
# question either way.

echo "==> granting codesign access to the signing key (one time)"
printf '    login password: '
read -rs KEYCHAIN_PASSWORD
echo

if [ -z "$KEYCHAIN_PASSWORD" ]; then
    echo "!! no password entered" >&2
    exit 1
fi

security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-key-partition-list -S "$PARTITIONS" -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN"

unset KEYCHAIN_PASSWORD

echo "==> done. Builds will not ask for a password again."
echo
echo "   This trusts codesign with every key in your login keychain, which is"
echo "   how the prompt is meant to be removed, and the usual trade for it."
echo "   To confirm, just build:"
echo
echo "       ./Scripts/build-app.sh"
echo
echo "   Your certificate exists only in this keychain now. That is normal, but"
echo "   it means a wiped keychain means a new certificate. To keep a backup:"
echo
echo "       security find-identity -v -p codesigning"
echo "       security export -k ~/Library/Desktop.p12 -t identities"
echo
echo "   Give that backup a password and store it somewhere safe. Do not commit"
echo "   it: .gitignore already refuses .p12 files, but a password-protected"
echo "   file on disk is still the thing that lets anyone sign as you."