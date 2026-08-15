# WalletKit — Rust workspace

Currently contains one crate, `walletkit-ffi`, a UniFFI export layer
covering software key management (BIP39 mnemonics, BIP32/SLIP-0010
derivation) so far. See `../Docs/Overview.md` for the target architecture
and `../Docs/Design Specification/` for the Swift API this crate backs.

For the full macOS + iOS (device + simulator) XCFramework build, use the
top-level `../Makefile` (`make walletkit-ffi`, `make test`, `make all`,
`make clean`) rather than the manual commands below — those are still
useful for quick host-only iteration while developing, but the Makefile is
what actually produces something Xcode can link against.

## Build (host-only, for local iteration)

```sh
cd walletkit-ffi
cargo build
```

## Test

Rust-side tests live alongside the code they cover, per
`../Docs/Overview.md`'s testing strategy:

```sh
cd walletkit-ffi
cargo test
```

## Generate Swift bindings

UniFFI's recommended "library mode" generates bindings straight from the
compiled library, so build first, then run the `uniffi-bindgen` binary
declared in `walletkit-ffi/Cargo.toml`:

```sh
cd walletkit-ffi
cargo build
cargo run --features cli --bin uniffi-bindgen -- generate \
    --library target/debug/libwalletkit_ffi.dylib \
    --language swift \
    --out-dir ../generated/swift
```

(`.dylib` on macOS; adjust the path/extension for other platforms.) This
generates the real `WalletKit.swift`/`.h`/`.modulemap` files — a separate
artifact from the hand-written API spec under
`Docs/Design Specification/`, which describes the *target* surface rather
than being compiled itself.
