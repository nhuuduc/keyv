#!/bin/zsh
# Create or export a persistent local code-signing certificate ("KeyV Code Signing")
# in a dedicated user keychain so macOS TCC Accessibility permissions survive
# rebuilds and auto-updates without requiring a paid Developer ID certificate.
#
# Usage:
#   ./scripts/setup_signing_cert.sh              # create/ensure local signing cert
#   ./scripts/setup_signing_cert.sh --export-ci  # print GitHub Actions secret instructions
set -euo pipefail

CERT_NAME="${KEYV_CERT_NAME:-KeyV Code Signing}"
CONFIG_DIR="$HOME/.config/keyv"
KEYCHAIN_PATH="$HOME/Library/Keychains/keyv-signing.keychain-db"
PASS_FILE="$CONFIG_DIR/signing-keychain-pass"
P12_BACKUP="$CONFIG_DIR/keyv-signing.p12"

mkdir -p "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"

if [ ! -f "$PASS_FILE" ]; then
  /usr/bin/openssl rand -hex 24 > "$PASS_FILE"
  chmod 600 "$PASS_FILE"
fi
KEYCHAIN_PASS="$(cat "$PASS_FILE")"

if [ ! -f "$KEYCHAIN_PATH" ]; then
  security create-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN_PATH"
fi

security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN_PATH"
security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"

existing_keychains=("${(@f)$(security list-keychains -d user | sed -E 's/^[[:space:]]*"(.*)"[[:space:]]*$/\1/')}")
if (( ! ${existing_keychains[(Ie)$KEYCHAIN_PATH]} )); then
  security list-keychains -d user -s "${existing_keychains[@]}" "$KEYCHAIN_PATH"
fi

if ! security find-identity -p codesigning "$KEYCHAIN_PATH" | grep -q "\"$CERT_NAME\""; then
  TMPDIR_CERT="$(mktemp -d)"
  trap 'rm -rf "$TMPDIR_CERT"' EXIT

  printf '%s\n' \
    "[ req ]" \
    "default_bits       = 2048" \
    "distinguished_name = req_dn" \
    "x509_extensions    = codesign_ext" \
    "prompt             = no" \
    "" \
    "[ req_dn ]" \
    "CN = $CERT_NAME" \
    "O  = KeyV" \
    "" \
    "[ codesign_ext ]" \
    "basicConstraints = critical, CA:FALSE" \
    "keyUsage         = critical, digitalSignature" \
    "extendedKeyUsage = critical, codeSigning" \
    "subjectKeyIdentifier = hash" > "$TMPDIR_CERT/openssl.cnf"

  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$TMPDIR_CERT/key.pem" \
    -out "$TMPDIR_CERT/cert.pem" \
    -days 3650 \
    -config "$TMPDIR_CERT/openssl.cnf" >/dev/null 2>&1

  /usr/bin/openssl pkcs12 -export \
    -legacy \
    -inkey "$TMPDIR_CERT/key.pem" \
    -in "$TMPDIR_CERT/cert.pem" \
    -name "$CERT_NAME" \
    -out "$P12_BACKUP" \
    -passout "pass:$KEYCHAIN_PASS" >/dev/null 2>&1 || \
  /usr/bin/openssl pkcs12 -export \
    -inkey "$TMPDIR_CERT/key.pem" \
    -in "$TMPDIR_CERT/cert.pem" \
    -name "$CERT_NAME" \
    -out "$P12_BACKUP" \
    -passout "pass:$KEYCHAIN_PASS" >/dev/null 2>&1

  chmod 600 "$P12_BACKUP"

  security import "$P12_BACKUP" \
    -k "$KEYCHAIN_PATH" \
    -P "$KEYCHAIN_PASS" \
    -T /usr/bin/codesign \
    -T /usr/bin/security >/dev/null

  security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s -k "$KEYCHAIN_PASS" \
    "$KEYCHAIN_PATH" >/dev/null

  echo "Created persistent signing identity: \"$CERT_NAME\" in $KEYCHAIN_PATH"
else
  echo "Signing identity already present: \"$CERT_NAME\" in $KEYCHAIN_PATH"
fi

security find-identity -p codesigning "$KEYCHAIN_PATH" | grep "\"$CERT_NAME\"" || true

if [[ "${1:-}" == "--export-ci" ]]; then
  if [ ! -f "$P12_BACKUP" ]; then
    echo "error: $P12_BACKUP not found" >&2
    exit 1
  fi
  echo ""
  echo "=== GitHub Actions Secrets (for persistent TCC-compatible CI releases) ==="
  echo "1. KEYV_CERT_PASSWORD:"
  echo "   $KEYCHAIN_PASS"
  echo ""
  echo "2. KEYV_CERT_P12_BASE64:"
  base64 -i "$P12_BACKUP" | tr -d '\n'
  echo ""
fi
