#!/bin/bash
# Build a Release build of xPaste, sign it with the stable self-signed identity, and
# install it into /Applications — replacing the running copy.
#
# Signing with the SAME certificate every time keeps the app's code-signing
# "designated requirement" constant, so macOS does NOT reset the Accessibility
# (TCC) permission on each rebuild. See README "Accessibility permission".
#
# One-time setup (already done once): a self-signed "Code Signing" certificate named
# below was created in the login keychain and trusted for code signing. To recreate it,
# see setup-signing-cert.sh.
set -euo pipefail

IDENTITY="xPaste Local Signing"
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
DERIVED="$PROJECT_DIR/build/release"
APP="$DERIVED/Build/Products/Release/xPaste.app"

# Fail early with a clear message if the signing identity is missing.
if ! security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
  echo "error: code signing identity '$IDENTITY' not found." >&2
  echo "       Run ./setup-signing-cert.sh first to create it." >&2
  exit 1
fi

echo "==> Building Release (signed as '$IDENTITY')…"
rm -rf "$DERIVED"
xcodebuild -project "$PROJECT_DIR/xPaste.xcodeproj" -scheme xPaste \
  -configuration Release -derivedDataPath "$DERIVED" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" \
  CODE_SIGNING_REQUIRED=YES CODE_SIGNING_ALLOWED=YES \
  | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true

[ -d "$APP" ] || { echo "error: build did not produce $APP" >&2; exit 1; }
codesign --verify --strict "$APP"

echo "==> Installing into /Applications…"
osascript -e 'tell application "xPaste" to quit' 2>/dev/null || true
pkill -x xPaste 2>/dev/null || true
sleep 1
rm -rf /Applications/xPaste.app.bak
[ -d /Applications/xPaste.app ] && mv /Applications/xPaste.app /Applications/xPaste.app.bak
ditto "$APP" /Applications/xPaste.app

echo "==> Launching…"
open /Applications/xPaste.app
echo "Done. Designated requirement:"
codesign -d --requirements - /Applications/xPaste.app 2>&1 | grep -i designated || true
