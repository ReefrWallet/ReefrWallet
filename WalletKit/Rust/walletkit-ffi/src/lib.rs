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
//!                   CoinType, Blockchain, DerivationPath
//!   keys/           Mnemonic, Seed, ExtendedKey, PublicKey, PrivateKey
//!   accounts/       KeySource, Account, KeyProvider — not implemented yet
//!   wallet/         Wallet, WalletBackup
//!   hardware/       HardwareVendor, HardwareTransportKind, HardwareDevice, ...
//!                   — not implemented yet
//!   blockchain_clients/  BlockchainClient, BlockchainAddress,
//!                   HardwareSigner — not implemented yet; EthereumClient,
//!                   EthereumAddress — implemented (Alloy-backed)

uniffi::setup_scaffolding!();

mod accounts;
pub mod blockchain_clients;
pub mod common;
pub mod errors;
mod hardware;
pub mod keys;
#[cfg(test)]
mod test_vectors;
pub mod wallet;
