#!/bin/zsh
# Package KeyV.app into distributable .zip, .dmg, and SHA256SUMS.txt artifacts.
# Usage: KEYV_VERSION=0.3.0 ./scripts/package_release.sh [output_dir]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_BUNDLE="$ROOT/apps/keyv-app/KeyV.app"
OUT_DIR="${1:-$ROOT/dist}"

[ -d "$APP_BUNDLE" ] || { echo "error: $APP_BUNDLE missing — run ./scripts/build.sh first" >&2; exit 1; }

RAW_VER="${KEYV_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_BUNDLE/Contents/Info.plist")}"
VERSION="${RAW_VER#v}"
ARCH_SUFFIX="${KEYV_ARCH_LABEL:-macos-universal}"

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

ZIP_VERSIONED="KeyV-${VERSION}-${ARCH_SUFFIX}.zip"
ZIP_LATEST="KeyV-macos.zip"
DMG_VERSIONED="KeyV-${VERSION}-${ARCH_SUFFIX}.dmg"

echo "==> Creating $ZIP_VERSIONED"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$OUT_DIR/$ZIP_VERSIONED"
cp "$OUT_DIR/$ZIP_VERSIONED" "$OUT_DIR/$ZIP_LATEST"

echo "==> Creating $DMG_VERSIONED"
DMG_STAGE="$(mktemp -d)"
trap 'rm -rf "$DMG_STAGE"' EXIT
cp -R "$APP_BUNDLE" "$DMG_STAGE/KeyV.app"
ln -s /Applications "$DMG_STAGE/Applications"

/usr/bin/hdiutil create \
  -volname "KeyV $VERSION" \
  -srcfolder "$DMG_STAGE" \
  -ov \
  -format UDZO \
  "$OUT_DIR/$DMG_VERSIONED" >/dev/null

echo "==> Generating SHA256SUMS.txt"
(
  cd "$OUT_DIR"
  shasum -a 256 "$ZIP_VERSIONED" "$ZIP_LATEST" "$DMG_VERSIONED" > SHA256SUMS.txt
)

cat "$OUT_DIR/SHA256SUMS.txt"
echo "Artifacts ready in: $OUT_DIR"
