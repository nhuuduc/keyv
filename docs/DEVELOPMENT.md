# Development notes

The primary architecture and usage documentation is in [README](../README.md).

For engine changes, run `cargo test --workspace` and Clippy. Test the Swift ABI
with `KeyVSmoke` after rebuilding the Rust static library and Swift executables.

To avoid replacing an already-authorized ad-hoc app during tests:

```sh
cargo build -p keyv-core --release
cp target/release/libkeyv_core.a apps/keyv-app/lib/
cd apps/keyv-app
swift build -c release
"$(swift build -c release --show-bin-path)/KeyVSmoke"
```

Only run `scripts/make_app.sh` when ready to replace the packaged application.
Its new ad-hoc identity may require granting Accessibility again. Never publish
runtime logs, clipboard databases, local preferences, signing keys or credentials.

The screenshots in this repository are captures of the running macOS app.
The partial ImageRenderer harness is not a substitute for checking native controls.
