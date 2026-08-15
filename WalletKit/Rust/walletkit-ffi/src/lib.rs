//! walletkit-ffi
//!
//! UniFFI export layer for WalletKit. See `Walletkit/Docs/Overview.md` for
//! the target architecture and `Walletkit/Docs/Design Specification/` for
//! the Swift API this crate backs.
//!
//! Module layout mirrors the Swift design spec's folders 1:1
//! (`core` is reserved by the standard library, so the Swift `Core/`
//! folder maps to `common` here):
//!
//!   errors/         WalletKitError
//!   common/         Curve, DerivationScheme, Wordlist, MnemonicWordCount,
//!                   Blockchain, DerivationPath
//!   keys/           Mnemonic, Seed, ExtendedKey, PublicKey, PrivateKey
//!   accounts/       KeySource, Account, KeyProvider — not implemented yet
//!   hardware/       HardwareVendor, HardwareTransportKind, HardwareDevice, ...
//!                   — not implemented yet
//!   blockchain_clients/  Signer, BlockchainAddress,
//!                   HardwareSigner — not implemented yet; EthereumSigner,
//!                   EthereumAddress — implemented (Alloy-backed);
//!                   SuiSigner, SuiAddress — address derivation only,
//!                   implemented (blake2-backed)

uniffi::setup_scaffolding!();

mod accounts;
pub mod blockchain_clients;
pub mod common;
pub mod errors;
mod hardware;
pub mod keys;
#[cfg(test)]
mod test_vectors;
