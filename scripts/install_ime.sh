#!/bin/zsh
# KeyV IME helper (P5) — optional install into ~/Library/Input Methods/.
# The main tap-based host does not require this; install only if the user
# prefers the InputMethodKit pipeline.
set -euo pipefail

APPDIR="$(cd "$(dirname "$0")/../apps/keyv-app" && pwd)"
BIN="$APPDIR/.build/out/Products/Release/KeyVIME"
RES="$APPDIR/Resources"

[ -x "$BIN" ] || { echo "error: $BIN missing — run scripts/build.sh"; exit 1; }

DEST="$HOME/Library/Input Methods/KeyV.app"
mkdir -p "$DEST/Contents/MacOS"
cp "$BIN" "$DEST/Contents/MacOS/KeyVIME"
cp "$RES/KeyVIME-Info.plist" "$DEST/Contents/Info.plist"
mkdir -p "$DEST/Contents/Resources"

codesign --force --sign - "$DEST" 2>/dev/null || true

echo "installed: $DEST"
echo "Enable in System Settings → Keyboard → Input Sources → +'KeyV' (then log out/in once)."
