//! walletkit-ffi
//!
//! UniFFI export layer for WalletKit. This crate is currently an empty
//! "hello world" scaffold proving out the Rust → UniFFI → Swift pipeline
//! end to end; no wallet APIs are implemented yet. See
//! `Walletkit/Docs/Overview.md` for the target architecture and
//! `Walletkit/Docs/Design Specification/` for the Swift API this crate
//! will eventually back.
//!
//! Module layout mirrors the Swift design spec's folders 1:1 so real
//! types can land in the matching module later without restructuring
//! (`core` is reserved by the standard library, so the Swift `Core/`
//! folder maps to `common` here):
//!
//!   errors/         WalletKitError
//!   common/         Curve, DerivationScheme, Wordlist, MnemonicWordCount,
//!                   CoinType, Blockchain, DerivationPath
//!   keys/           Mnemonic, Seed, ExtendedKey, PublicKey, PrivateKey
//!   accounts/       KeySource, Account, KeyProvider
//!   wallet/         Wallet, WalletBackup
//!   hardware/       HardwareVendor, HardwareTransportKind, HardwareDevice, ...
//!   chain_clients/  ChainClient, HardwareChainSigner
//!
//! Every module below is intentionally empty.

uniffi::setup_scaffolding!();

mod accounts;
mod chain_clients;
mod common;
mod errors;
mod hardware;
mod keys;
mod wallet;

/// Temporary hello-world export used to prove the UniFFI pipeline (Rust →
/// generated Swift bindings → Xcode) end to end before any real API
/// lands. Remove once the first real export (e.g. `Mnemonic::generate`)
/// is implemented.
#[uniffi::export]
pub fn hello_world() -> String {
    "Hello, World!".to_string()
}
