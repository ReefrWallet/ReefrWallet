# WalletKit — Architecture Overview

WalletKit is the shared key-management and blockchain-access core for
Reefr Wallet. It is implemented in Rust and exposed to Swift (iOS/macOS) 
via UniFFI. This document covers mnemonic-based key management plus
hardware wallets (Trezor first) as a second, first-class key source. 
Chain clients (Bitcoin, Ethereum, Tron, Solana, Cardano, Sui) are a later
phase and are called out below only as extension points.

## Goals

- Single audited Rust core for all cryptography and key derivation; no
  duplicated crypto logic on the Swift side.
- Modular crate layout so blockchain-specific clients can be added later
  without touching the key-management core.
- Swift-facing API that reads as idiomatic Swift, not a thin C shim —
  UniFFI's Swift bindings should feel native to a GUI app.
- Security-first FFI boundary: sensitive material stays opaque and inside
  Rust wherever possible; raw exports are explicit, rare, and clearly named.
- Testable against official BIP39 / BIP32 / SLIP-0010 test vectors from day
  one, independent of any chain client.
- Testable against pre-configured test wallets on testnet for every
  supported blockchain.
- Hardware wallets (Trezor first) are a key *source*, not a bolted-on
  special case — software and hardware accounts expose the same
  `KeyProvider`/`Account` surface wherever the operation is genuinely
  identical (address/public-key retrieval), and diverge only where the
  underlying reality actually differs (signing).

## Crate layout

- `walletkit-keys` — software key management. BIP39 mnemonics, seed
  derivation, BIP32 (secp256k1) and SLIP-0010 (ed25519) hierarchical
  derivation, signing. No networking, no persistence, no chain-specific
  logic.
- `walletkit-hardware` — vendor-agnostic hardware wallet plumbing: the
  `KeyProvider`/`Account`/`HardwareDevice` traits, transport enumeration,
  the async delegate/callback mechanism for host-side PIN/passphrase/button
  prompts, and error mapping. Defines the contract; carries no vendor
  protocol code itself.
- `walletkit-trezor` — implements `walletkit-hardware`'s traits for Trezor
  devices. Wraps the official `trezor-client` crate (from
  `trezor/trezor-firmware`, the Trezor team's own Rust client covering the
  wire protocol/protobuf messages) rather than reimplementing the protocol
  — same "don't hand-roll audited/reference protocol code" principle as
  the crypto primitives. USB transport first; Bluetooth (needed for Trezor
  Safe 7 on iOS) added once the base plumbing is proven on macOS/USB.
- `walletkit-ffi` — UniFFI export layer. Wraps `walletkit-keys`,
  `walletkit-hardware` (+ vendor crates), and later chain crates behind
  `#[uniffi::export]` proc-macros; this is what gets compiled into the
  XCFramework Swift links against. Also where UniFFI's callback-interface
  support is wired up so `HardwareDeviceDelegate` (Swift) can be called
  from in-flight Rust/device operations.
- `walletkit-<chain>` (future) — one crate per chain (e.g.
  `walletkit-bitcoin`, `walletkit-ethereum`, `walletkit-solana`,
  `walletkit-cardano`, `walletkit-sui`, `walletkit-tron`). Each implements
  `ChainClient` (address derivation) against `Account`, and, once needed,
  a per-(chain, vendor) `HardwareChainSigner` for hardware signing — see
  "Hardware wallet support" below for why that can't be one shared trait
  across vendors. Not implemented yet.
- `walletkit-<chain>-<vendor>` (future, as needed) — thin crates for
  hardware signing adapters that don't naturally belong inside either the
  chain crate or the vendor crate (e.g. `walletkit-ethereum-trezor`),
  added only if the (chain, vendor) matrix gets unwieldy inside the chain
  crates themselves. Not a phase-1 decision — noted so the seam is
  visible.
- Workspace is structured so `walletkit-ffi` can select which chain and
  vendor crates are compiled in — a GUI app that only needs Bitcoin +
  Ethereum shouldn't have to ship Cardano's CBOR/CSL dependencies, and an
  app with no hardware wallet support shouldn't have to link
  `walletkit-trezor` at all.

## Phase 1 scope: key management

- **Mnemonic** — BIP39 generation (12/15/18/21/24 words) and import,
  wordlist-aware (English at launch, extensible), validated against the
  BIP39 checksum.
- **Seed** — BIP39 seed derivation from mnemonic + optional passphrase
  (25th word). Opaque type; exposes derivation, not raw bytes, on the
  common path.
- **Extended keys / HD derivation** — a single `ExtendedKey` abstraction
  covering both supported schemes:
  - BIP32 for secp256k1-based chains (Bitcoin, Ethereum, Tron, ...).
  - SLIP-0010 for ed25519-based chains (Solana, Sui, ...).
  - Supports path-based derivation (`m/44'/60'/0'/0/0`), single-child
    derivation, and xpub/xprv-style serialization for import/export.
- **DerivationPath / CoinType / Blockchain** — `CoinType` is a small SLIP-44
  coin registry (bitcoin, ethereum, tron, solana, cardano, sui: curve +
  coin index). `Blockchain` wraps a `CoinType` and knows how to produce
  that chain's standard derivation path from it — it's the identifier
  `Account`, `KeyProvider`, and `ChainClient` are actually built around, so
  callers work with `Blockchain.ethereum` etc. rather than assembling
  curve/path constants by hand.
- **PrivateKey / PublicKey** — curve-tagged key handles. Signing happens
  inside Rust (`privateKey.sign(message:)`); there is intentionally no
  general "give me the raw private key bytes" call on the hot path.
- **Wallet facade** — convenience type wrapping mnemonic + seed +
  derivation for the common case (`Wallet.create()`, `.restore(phrase:)`,
  `.account(blockchain:)`), while the lower-level types stay available for
  advanced use.
- **Backup / restore** — plaintext backup payload (mnemonic + metadata) for
  callers who manage their own encrypted storage, plus a built-in
  password-based encrypted export/import path for convenience.

## Hardware wallet support

- **What ships now vs. later.** This phase covers device discovery,
  connection/session lifecycle, the host-input/confirmation callback
  model, and public-key/address retrieval (`KeyProvider.publicKey`,
  `KeyProvider.account`) for hardware devices — genuinely useful today
  (e.g. show a receive address from a connected Trezor) and identical in
  shape to the software path. It does **not** yet cover hardware signing.
- **Why signing is deferred, deliberately, not by oversight.** Software
  signing is "sign these bytes with this key" — one shape, works for every
  chain. Hardware signing is not: Trezor's wire protocol has a distinct
  message type per chain (`SignTx` for Bitcoin, `EthereumSignTx` for
  Ethereum, and so on), often carrying structured, chain-specific fields
  rather than a raw digest, because the device's trusted screen needs to
  decode and display what it's signing — that's the whole security
  property of a hardware wallet. There is no honest single
  `sign(digest:)` that fits both software and every chain's hardware
  message. `HardwareChainSigner` is the placeholder seam for this; it gets
  filled in per (chain, vendor) once a chain module is actually built.
- **`KeyProvider` unifies identity, not signing.** `Wallet` (software) and
  `HardwareDevice` (hardware) both conform to `KeyProvider` and both
  produce `Account` — a source-agnostic handle carrying a `Blockchain`,
  derivation path, curve, public key, and `KeySource`. GUI code that only
  needs "what's the address / which accounts exist" never branches on
  software vs. hardware. Code that needs to actually sign does branch,
  necessarily, at the chain-client layer.
- **Interactive operations need a callback, not just async/throws.**
  Trezor operations can require mid-flight host input (PIN typed against a
  device-displayed matrix, an on-host passphrase) or a physical
  confirmation the user performs on the device itself. `HardwareDeviceDelegate`
  is a UniFFI *callback interface* — Rust holds a reference to a
  Swift-implemented object and calls into it while an operation is
  in-flight — rather than a single request/response call. This is a step
  up in FFI complexity from phase 1's plain function calls and is worth
  prototyping early (a "connect + read one public key" spike) before
  building real functionality on top of it.
- **Transport and platform constraints are real and vendor/model-specific,
  not just an implementation detail:**
  - macOS: USB HID access is practical (IOKit + the appropriate
    sandbox entitlement if sandboxed). All current Trezor models
    (One, T, Safe 3, Safe 5, Safe 7) work over USB on macOS.
  - iOS: no generic USB HID access without MFi certification, and Trezor
    devices are not MFi-certified — so USB-connected Trezors cannot sign
    from an iOS app. Trezor Safe 7 adds Bluetooth and is, as of now, the
    only Trezor model with a real iOS signing story. Other models on iOS
    are limited to whatever a companion bridge could offer (viewing
    balances/addresses) — not signing.
  - Practical implication: hardware wallet support should be built and
    tested macOS-first. iOS support should be scoped explicitly per
    device model rather than assumed to follow automatically.
  - `.qrAirGap` is included in `HardwareTransportKind` even though no
    targeted vendor uses it yet, because it's the one transport with no
    iOS/macOS asymmetry (camera access only) — worth keeping in mind if
    iOS parity for hardware wallets matters later.
- **Don't reimplement the device protocol.** Use the Trezor team's own
  `trezor-client` Rust crate for the wire protocol rather than
  hand-rolling protobuf message handling — same reasoning as using
  audited crypto crates instead of custom implementations in
  `walletkit-keys`.

## Known future special case: Cardano

Cardano does not use plain SLIP-0010 — it uses a variant of BIP32-Ed25519
(CIP-1852 paths, extended 96-byte keys, different child-key derivation
math). `Blockchain.cardano` (backed by `CoinType.cardano`) is registered
now for address/path bookkeeping, but full support requires a dedicated
derivation path inside `walletkit-keys` (or its own crate) before the
Cardano chain client can ship. Called out here so it isn't a surprise
later.

## Security model

- Mnemonic, seed, and private key material are zeroized on drop inside
  Rust (`zeroize` crate or equivalent).
- Sensitive types cross the FFI boundary as opaque UniFFI objects
  (`ExtendedKey`, `PrivateKey`, `Seed`) rather than raw `Data`/`String`
  wherever the operation can be expressed as "do the thing in Rust and
  return the result" instead of "hand me the bytes."
- Explicit raw-export functions (`Seed.exportRaw()`,
  `ExtendedKey.serializedPrivate()`, `Wallet.exportBackup()`) exist for
  legitimate backup/import flows, are individually named, and are not
  called implicitly by anything else in the library.
- WalletKit never persists keys itself. Storage (Keychain, Secure Enclave
  wrapping, on-disk encrypted files) is entirely the host app's
  responsibility; WalletKit only produces and consumes in-memory material
  and opaque encrypted backup blobs.
- Swift-side callers should treat any `String`/`Data` returned from a raw
  export call as sensitive for the lifetime of the process — Swift value
  types aren't zeroized automatically, so minimize how long they're held
  and avoid logging them.
- Hardware-sourced keys never have raw material cross the FFI boundary at
  all — by construction, not just convention. `HardwareDevice` only ever
  returns public keys and (once implemented) signatures; there is no
  `HardwareDevice.exportPrivateKey()`-shaped call anywhere in the design,
  because the device itself never releases one.

## FFI / bindings strategy

- UniFFI proc-macro exports (`#[uniffi::export]`) rather than `.udl` files,
  so each crate can declare its own exported surface and stay modular as
  chain crates are added.
- Errors surface to Swift as a single `WalletKitError` enum conforming to
  `Error`, generated from a `thiserror`-based Rust error type.
- Object types (`Mnemonic`, `Seed`, `ExtendedKey`, `PrivateKey`,
  `PublicKey`, `Wallet`) become UniFFI `interface` types → Swift classes;
  value types (`DerivationPath`, `CoinType`, `Blockchain`, `WalletBackup`,
  enums) become UniFFI `record`/`enum` types → Swift structs/enums.
- Packaged as an XCFramework + Swift package (`WalletKit`), consumed by the
  GUI app via SPM.
- Software key derivation/signing is CPU-bound and fast, but the
  `KeyProvider` surface (`publicKey`, `account`) is `async` uniformly
  across software and hardware so callers don't need two code paths.
  Hardware operations additionally rely on UniFFI's callback-interface
  support (`HardwareDeviceDelegate`) so Rust can call back into Swift
  mid-operation. Future chain clients' networking (RPC calls) fits the
  same async story without a breaking change to how Swift consumes it.

## Explicitly out of scope for now

- Any blockchain-specific logic: address formatting, transaction building,
  fee estimation, RPC/networking.
- Hardware *signing* (see "Hardware wallet support" above — deferred to
  land with each chain client, not skipped).
- Additional hardware vendors beyond Trezor (Ledger, Keystone, ...) — the
  abstraction is written to accommodate them, but none are being built yet.
- Persistence of any kind (Keychain integration lives in the host app).
- UI/state management (this is a headless library).

## Testing strategy

- Testing happens at two layers, on two sides of the FFI boundary, and both
  are required — neither substitutes for the other:
  - **Rust tests, in the `walletkit-*` crates themselves.** Standard
    `cargo test` unit/integration tests living alongside the code they
    cover (`walletkit-keys`, `walletkit-hardware`, `walletkit-trezor`, and
    each `walletkit-<chain>` crate as it lands). This is where correctness
    of the actual cryptography, derivation math, and protocol handling is
    proven — fast, no FFI/UniFFI/XCFramework build involved, runs on every
    commit.
  - **Swift tests, against the exported WalletKit API.** A Swift test
    target that consumes the generated UniFFI bindings the same way the
    GUI app would — `import WalletKit` and call `Mnemonic`, `Wallet`,
    `HardwareDeviceManager`, etc. through their public Swift surface, not
    through Rust directly. This is what catches bugs the Rust-side tests
    can't see: incorrect UniFFI type mapping, wrong Swift-facing defaults/
    optionality, async/callback-interface behavior (`HardwareDeviceDelegate`)
    actually working across the boundary, and `WalletKitError` cases
    surfacing as the right Swift `Error`. Runs against a real built
    XCFramework, so it's slower and belongs in CI, not necessarily on
    every local edit.
- Unit tests against official BIP39 test vectors (multiple languages'
  wordlists as they're added) and BIP32/SLIP-0010 reference test vectors —
  Rust-side, in `walletkit-keys`.
- Cross-check derived keys/addresses against a second independent
  implementation (e.g. a small script using an established library) before
  trusting a derivation path in the GUI.
- Fuzz/property tests around mnemonic parsing and path parsing, since both
  take untrusted string input (user-typed recovery phrases, custom paths) —
  Rust-side.
- Hardware wallet testing can't rely on test vectors the way software
  derivation can — plan for both Trezor's own device emulator (used by the
  `trezor-client`/`trezorlib` test suites) for CI, and periodic manual
  testing against real hardware before any hardware-signing release. The
  emulator-backed cases belong in Rust (`walletkit-trezor`); the
  Swift-side hardware tests focus on the delegate/callback plumbing and
  error mapping rather than re-verifying device protocol correctness.
