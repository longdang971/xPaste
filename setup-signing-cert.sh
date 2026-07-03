#!/bin/bash
# One-time: create a self-signed "Code Signing" certificate in the login keychain and
# trust it for code signing. Building xPaste with this identity (see build-release.sh)
# gives the app a STABLE code-signing designated requirement, so macOS keeps its
# Accessibility (TCC) permission across rebuilds instead of resetting it every time.
#
# Safe to skip if `security find-identity -v -p codesigning` already lists the identity.
set -euo pipefail

IDENTITY="xPaste Local Signing"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
  echo "Identity '$IDENTITY' already exists — nothing to do."
  exit 0
fi

echo "==> Generating self-signed code-signing certificate…"
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 3650 \
  -subj "/CN=$IDENTITY" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning"

# -legacy so macOS's `security import` can read the PKCS#12 MAC (OpenSSL 3 default is too new).
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/identity.p12" -passout pass:xpaste -name "$IDENTITY"

echo "==> Importing into login keychain (allow codesign to use it)…"
security import "$TMP/identity.p12" -k ~/Library/Keychains/login.keychain-db -P xpaste -T /usr/bin/codesign

echo "==> Trusting the certificate for code signing (you may be asked for your password)…"
security add-trusted-cert -r trustRoot -p codeSign -k ~/Library/Keychains/login.keychain-db "$TMP/cert.pem"

echo "==> Done. Valid identities:"
security find-identity -v -p codesigning | grep "$IDENTITY"
