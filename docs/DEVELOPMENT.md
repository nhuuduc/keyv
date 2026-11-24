# Development & Release Guide

Primary user documentation is in [README.md](../README.md).

## Verification Workflow

Run all Rust checks and Swift FFI/host/updater smoke checks before opening a PR:

```sh
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
./scripts/build.sh
```

To build a universal (`arm64` + `x86_64`) release bundle and generate `.zip`, `.dmg`, and `SHA256SUMS.txt` artifacts locally:

```sh
KEYV_UNIVERSAL=1 ./scripts/build.sh
./scripts/package_release.sh dist
```

## Persistent Code Signing & macOS TCC Permissions

macOS ties Accessibility (`kTCCServiceAccessibility`) grants to the bundle's Designated Requirement. Ad-hoc signatures (`codesign -s -`) pin the requirement to a binary-specific `cdhash`, invalidating Accessibility permission after rebuilds or updates.

- **Local development**: run `./scripts/setup_signing_cert.sh` once. It creates `~/Library/Keychains/keyv-signing.keychain-db` with a persistent `KeyV Code Signing` certificate. `scripts/make_app.sh` automatically discovers and signs `KeyV.app` with this identity.
- **CI Releases (`.github/workflows/release.yml`)**: run `./scripts/setup_signing_cert.sh --export-ci` (or export an Apple `Developer ID Application` `.p12`) and add `KEYV_CERT_P12_BASE64` and `KEYV_CERT_PASSWORD` to GitHub Repository Secrets. Optional Apple Notarization runs automatically when a `Developer ID Application` identity is paired with `APPLE_ID`, `APPLE_TEAM_ID`, and `APPLE_APP_SPECIFIC_PASSWORD`.

Never commit `.p12`, `.key`, keychain files, runtime logs, or local SQLite clipboard databases.
