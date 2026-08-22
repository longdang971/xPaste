#!/bin/bash
# Runs the Debug build for hands-on testing.
#
# Quits the installed copy first: two instances poll the same pasteboard, fight over ⇧⌘V, and —
# the part that matters — write to the same history directory. Puts it back when you quit.
set -uo pipefail
APP="$(cd "$(dirname "$0")" && pwd)/build/debug/Build/Products/Debug/xPaste.app"
[ -d "$APP" ] || { echo "no Debug build at $APP — run: xcodebuild -scheme xPaste -configuration Debug -derivedDataPath build/debug build"; exit 1; }

WAS_RUNNING=0
if pgrep -f "/Applications/xPaste.app/Contents/MacOS/xPaste" >/dev/null; then
  WAS_RUNNING=1
  echo "==> quitting the installed copy…"
  osascript -e 'tell application "xPaste" to quit' 2>/dev/null || pkill -f "/Applications/xPaste.app" || true
  sleep 1
fi

echo "==> running the Debug build (⇧⌘V opens the panel; ⌃C here to stop)"
"$APP/Contents/MacOS/xPaste"

if [ "$WAS_RUNNING" = 1 ]; then
  echo "==> putting the installed copy back…"
  open /Applications/xPaste.app
fi
