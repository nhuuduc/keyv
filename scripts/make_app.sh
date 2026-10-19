#!/bin/zsh
# Assemble KeyV.app from the release binary (run scripts/build.sh first).
set -euo pipefail

APPDIR="$(cd "$(dirname "$0")/../apps/keyv-app" && pwd)"
BIN_DIR="$(cd "$APPDIR" && swift build -c release --show-bin-path)"
BIN="$BIN_DIR/KeyVApp"
RES="$APPDIR/Resources"

[ -x "$BIN" ] || { echo "error: $BIN missing — run scripts/build.sh"; exit 1; }

BUNDLE="$APPDIR/KeyV.app"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN" "$BUNDLE/Contents/MacOS/KeyVApp"
cp "$RES/KeyV-Info.plist" "$BUNDLE/Contents/Info.plist"

# Icon generated later; keep optional.
[ -f "$RES/KeyV.icns" ] && cp "$RES/KeyV.icns" "$BUNDLE/Contents/Resources/" || true

# SwiftPM target resource bundles (Bundle.module lookups read these).
for src in "$BIN_DIR"/*_KeyV*.bundle; do
  [ -e "$src" ] && cp -R "$src" "$BUNDLE/Contents/Resources/" || true
done

# Use the same certificate for every build to retain macOS privacy identity.
# Ad-hoc signing is a local fallback; its identity changes with the binary.
SIGNING_IDENTITY="${KEYV_SIGNING_IDENTITY:--}"
if [ "$SIGNING_IDENTITY" = "-" ]; then
  echo "warning: ad-hoc build; macOS may require granting Accessibility again after rebuilding." >&2
fi
codesign --force --sign "$SIGNING_IDENTITY" "$BUNDLE"
codesign --verify --strict "$BUNDLE"
echo "bundled: $BUNDLE"
