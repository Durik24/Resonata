#!/bin/bash
# Creates a self-signed code-signing certificate called "Resonata Dev" in your
# login keychain and trusts it for code signing. Run this once.
#
# Why this exists
# ---------------
# build.sh used to sign ad-hoc (`codesign --sign -`). An ad-hoc signature is a
# hash of the binary, so every rebuild gave the app a brand-new identity — and
# macOS ties permissions to identity. Each rebuild silently revoked Automation
# (reading Spotify) and Screen Recording (the audio the spectrum listens to),
# and the app looked broken until they were granted again.
#
# A real certificate keeps the identity the same across builds, so you grant
# each permission once and it sticks.
#
# You'll be asked for your login password once or twice. That's the keychain
# asking, not this script — it never sees the password.
set -euo pipefail

NAME="Resonata Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
    echo "\"$NAME\" already exists in your keychain. Nothing to do."
    exit 0
fi

echo "Creating certificate \"$NAME\"..."
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -subj "/CN=$NAME" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "basicConstraints=critical,CA:false" \
    2>/dev/null

# The p12 password is throwaway: the file lives in a temp dir for a second.
openssl pkcs12 -export -out "$WORK/identity.p12" \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -passout pass:resonata

echo "Importing into your login keychain..."
# -T pre-authorises codesign, so it doesn't ask for the password on every build.
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P resonata \
    -T /usr/bin/codesign -T /usr/bin/security >/dev/null

echo "Trusting it for code signing (this is the step that asks for your password)..."
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

echo
echo "Done. Next:"
echo "  ./build.sh run"
echo "Then grant Automation (Spotify/Music) and Screen Recording when asked."
echo "They will now survive rebuilds."
