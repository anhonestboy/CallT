#!/bin/bash
# Creates a local self-signed code-signing certificate ("CallT Local Signing")
# and imports it into the login keychain. Signing the app with a stable
# identity makes macOS permissions (Screen Recording, Microphone) survive
# app updates — with ad-hoc signing they reset on every rebuild.
#
# Run it YOURSELF (it touches your keychain): bash scripts/make-signing-cert.sh
# macOS may show 1-2 dialogs: approve and choose "Always Allow".
set -euo pipefail

NAME="CallT Local Signing"
DIR=$(mktemp -d)
trap 'rm -rf "$DIR"' EXIT

if security find-identity -v -p codesigning | grep -q "$NAME"; then
  echo "✓ Certificate \"$NAME\" already exists and is valid."
  exit 0
fi

echo "→ Generating certificate (valid 10 years)…"
openssl req -x509 -newkey rsa:2048 -keyout "$DIR/key.pem" -out "$DIR/cert.pem" \
  -days 3650 -nodes -subj "/CN=$NAME" \
  -addext "extendedKeyUsage=codeSigning" \
  -addext "keyUsage=digitalSignature" \
  -addext "basicConstraints=critical,CA:false" 2>/dev/null

PASS=$(uuidgen)
openssl pkcs12 -export -out "$DIR/callt.p12" -inkey "$DIR/key.pem" \
  -in "$DIR/cert.pem" -passout "pass:$PASS"

echo "→ Importing into the login keychain…"
security import "$DIR/callt.p12" -k ~/Library/Keychains/login.keychain-db \
  -P "$PASS" -T /usr/bin/codesign

echo "→ Trusting the certificate for code signing (a dialog may appear)…"
security add-trusted-cert -p codeSign -k ~/Library/Keychains/login.keychain-db "$DIR/cert.pem"

echo
security find-identity -v -p codesigning | grep "$NAME" \
  && echo "✓ Done. Rebuild with scripts/build.sh: it will sign with \"$NAME\" automatically." \
  || { echo "✗ The identity is not valid yet — open Keychain Access and check the certificate."; exit 1; }
