#!/bin/zsh
# Assemble and sign KeyV.app from the release binary (run scripts/build.sh first).
set -euo pipefail

APPDIR="$(cd "$(dirname "$0")/../apps/keyv-app" && pwd)"
RES="$APPDIR/Resources"
BUNDLE_ID="app.keyv.host"

if [ -n "${KEYV_BIN_PATH:-}" ]; then
  BIN="$KEYV_BIN_PATH"
  BIN_DIR="$(dirname "$BIN")"
else
  if [ "${KEYV_UNIVERSAL:-0}" = "1" ] && [ -x "$APPDIR/.build/apple/Products/Release/KeyVApp" ]; then
    BIN_DIR="$APPDIR/.build/apple/Products/Release"
  else
    BIN_DIR="$(cd "$APPDIR" && swift build -c release --show-bin-path)"
  fi
  BIN="$BIN_DIR/KeyVApp"
fi

[ -x "$BIN" ] || { echo "error: $BIN missing — run scripts/build.sh" >&2; exit 1; }

BUNDLE="$APPDIR/KeyV.app"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN" "$BUNDLE/Contents/MacOS/KeyVApp"
cp "$RES/KeyV-Info.plist" "$BUNDLE/Contents/Info.plist"

if [ -n "${KEYV_VERSION:-}" ]; then
  CLEAN_VER="${KEYV_VERSION#v}"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $CLEAN_VER" "$BUNDLE/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $CLEAN_VER" "$BUNDLE/Contents/Info.plist"
fi

[ -f "$RES/KeyV.icns" ] && cp "$RES/KeyV.icns" "$BUNDLE/Contents/Resources/" || true

for src in "$BIN_DIR"/*_KeyV*.bundle; do
  [ -e "$src" ] && cp -R "$src" "$BUNDLE/Contents/Resources/" || true
done

LOCAL_SIGNING_KEYCHAIN="$HOME/Library/Keychains/keyv-signing.keychain-db"
LOCAL_SIGNING_PASS_FILE="$HOME/.config/keyv/signing-keychain-pass"
if [ -f "$LOCAL_SIGNING_KEYCHAIN" ] && [ -f "$LOCAL_SIGNING_PASS_FILE" ]; then
  security unlock-keychain -p "$(cat "$LOCAL_SIGNING_PASS_FILE")" "$LOCAL_SIGNING_KEYCHAIN" 2>/dev/null || true
fi

resolve_signing_identity() {
  if [ -n "${KEYV_SIGNING_IDENTITY:-}" ]; then
    echo "$KEYV_SIGNING_IDENTITY"
    return
  fi

  local valid_identities
  valid_identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"

  local dev_id
  dev_id="$(echo "$valid_identities" | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -n 1)"
  if [ -n "$dev_id" ]; then
    echo "$dev_id"
    return
  fi

  if [ -f "$LOCAL_SIGNING_KEYCHAIN" ]; then
    local local_sha1
    local_sha1="$(security find-identity -p codesigning "$LOCAL_SIGNING_KEYCHAIN" 2>/dev/null | sed -n 's/^[[:space:]]*[0-9][0-9]*)[[:space:]]*\([0-9A-F]\{40\}\)[[:space:]]*"KeyV Code Signing.*/\1/p' | head -n 1)"
    if [ -n "$local_sha1" ]; then
      echo "$local_sha1"
      return
    fi
  fi

  local all_identities
  all_identities="$(security find-identity -p codesigning 2>/dev/null || true)"
  local any_keyv_sha1
  any_keyv_sha1="$(echo "$all_identities" | sed -n 's/^[[:space:]]*[0-9][0-9]*)[[:space:]]*\([0-9A-F]\{40\}\)[[:space:]]*"KeyV Code Signing.*/\1/p' | head -n 1)"
  if [ -n "$any_keyv_sha1" ]; then
    echo "$any_keyv_sha1"
    return
  fi

  local apple_dev
  apple_dev="$(echo "$valid_identities" | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -n 1)"
  if [ -n "$apple_dev" ]; then
    echo "$apple_dev"
    return
  fi

  echo "-"
}

SIGNING_IDENTITY="$(resolve_signing_identity)"
CODESIGN_EXTRA_ARGS=()
KEYCHAIN_ARGS=()

if [ -n "${KEYV_KEYCHAIN_PATH:-}" ]; then
  KEYCHAIN_ARGS=(--keychain "$KEYV_KEYCHAIN_PATH")
elif [[ "$SIGNING_IDENTITY" =~ ^[0-9A-F]{40}$ ]] && [ -f "$LOCAL_SIGNING_KEYCHAIN" ]; then
  KEYCHAIN_ARGS=(--keychain "$LOCAL_SIGNING_KEYCHAIN")
fi

if [[ "$SIGNING_IDENTITY" == "Developer ID Application:"* ]]; then
  CODESIGN_EXTRA_ARGS=(--options runtime --timestamp)
fi

for nested in "$BUNDLE/Contents/Resources/"*.bundle; do
  if [ -d "$nested" ]; then
    codesign --force --sign "$SIGNING_IDENTITY" "${KEYCHAIN_ARGS[@]}" "${CODESIGN_EXTRA_ARGS[@]}" "$nested"
  fi
done

if [ "$SIGNING_IDENTITY" = "-" ]; then
  echo "warning: ad-hoc signature active; run ./scripts/setup_signing_cert.sh once so macOS TCC Accessibility permissions persist across updates." >&2
  codesign --force --sign - --identifier "$BUNDLE_ID" "$BUNDLE"
else
  echo "signing KeyV.app with identity: $SIGNING_IDENTITY"
  codesign --force --sign "$SIGNING_IDENTITY" \
    --identifier "$BUNDLE_ID" \
    --entitlements "$RES/KeyV.entitlements" \
    "${KEYCHAIN_ARGS[@]}" \
    "${CODESIGN_EXTRA_ARGS[@]}" \
    "$BUNDLE"
fi

codesign --verify --deep --strict "$BUNDLE"
codesign -d -r- "$BUNDLE" 2>&1 | sed 's/^/  /'
echo "bundled: $BUNDLE"
