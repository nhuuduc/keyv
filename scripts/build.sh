#!/bin/zsh
# KeyV — full build: Rust staticlib + Swift host apps.
# Usage: ./scripts/build.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$HOME/.cargo/bin:$PATH"

echo "==> Rust staticlib (keyv-core)"
(cd "$ROOT" && cargo build -p keyv-core --release)

APP="$ROOT/apps/keyv-app"
mkdir -p "$APP/lib" "$APP/Sources/CKeyV/include"
cp "$ROOT/target/release/libkeyv_core.a" "$APP/lib/"
cp "$ROOT/crates/keyv-core/include/keyv.h" "$APP/Sources/CKeyV/include/keyv.h"

if [ ! -f "$APP/Resources/KeyV.icns" ] || [ ! -f "$APP/Sources/KeyVHostKit/KeyVIcon.png" ]; then
  echo "==> App icon"
  (cd "$ROOT" && swift scripts/make_icon.swift)
fi

echo "==> Swift host (release)"
(cd "$APP" && swift build -c release)

echo "==> FFI smoke (Swift layer)"
BIN_DIR="$(cd "$APP" && swift build -c release --show-bin-path)"
"$BIN_DIR/KeyVSmoke"

echo "==> Bundle KeyV.app"
"$ROOT/scripts/make_app.sh"
echo "Done: $APP/KeyV.app"
