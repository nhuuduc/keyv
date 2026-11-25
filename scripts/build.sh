#!/bin/zsh
# KeyV — full build: Rust staticlib + Swift host apps.
# Usage:
#   ./scripts/build.sh
#   KEYV_UNIVERSAL=1 ./scripts/build.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:$PATH"

APP="$ROOT/apps/keyv-app"
mkdir -p "$APP/lib" "$APP/Sources/CKeyV/include"
cp "$ROOT/crates/keyv-core/include/keyv.h" "$APP/Sources/CKeyV/include/keyv.h"

if [ "${KEYV_UNIVERSAL:-0}" = "1" ]; then
  echo "==> Rust staticlib (keyv-core, universal arm64 + x86_64)"
  if command -v rustup >/dev/null 2>&1; then
    rustup target add aarch64-apple-darwin x86_64-apple-darwin >/dev/null 2>&1 || true
  fi
  (cd "$ROOT" && cargo build -p keyv-core --release --target aarch64-apple-darwin)
  (cd "$ROOT" && cargo build -p keyv-core --release --target x86_64-apple-darwin)
  lipo -create \
    "$ROOT/target/aarch64-apple-darwin/release/libkeyv_core.a" \
    "$ROOT/target/x86_64-apple-darwin/release/libkeyv_core.a" \
    -output "$APP/lib/libkeyv_core.a"
else
  echo "==> Rust staticlib (keyv-core)"
  (cd "$ROOT" && cargo build -p keyv-core --release)
  cp "$ROOT/target/release/libkeyv_core.a" "$APP/lib/"
fi

if [ ! -f "$APP/Resources/KeyV.icns" ] || [ ! -f "$APP/Sources/KeyVHostKit/KeyVIcon.png" ]; then
  echo "==> App icon"
  (cd "$ROOT" && swift scripts/make_icon.swift)
fi

if [ "${KEYV_UNIVERSAL:-0}" = "1" ]; then
  echo "==> Swift host (release, universal arm64 + x86_64)"
  (cd "$APP" && swift build -c release --arch arm64 --arch x86_64)
  BIN_DIR="$(cd "$APP" && swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
else
  echo "==> Swift host (release)"
  (cd "$APP" && swift build -c release)
  BIN_DIR="$(cd "$APP" && swift build -c release --show-bin-path)"
fi

echo "==> FFI & host smoke tests (Swift layer)"
"$BIN_DIR/KeyVSmoke"

echo "==> Bundle KeyV.app"
KEYV_BIN_PATH="$BIN_DIR/KeyVApp" "$ROOT/scripts/make_app.sh"
echo "Done: $APP/KeyV.app"
