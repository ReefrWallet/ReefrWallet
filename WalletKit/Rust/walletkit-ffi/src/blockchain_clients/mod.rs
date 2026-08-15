//! Blockchain-client extension points. See
//! `Walletkit/Docs/Design Specification/Clients/` for the target Swift
//! shape: `Signer`, `BlockchainAddress`, `HardwareSigner`,
//! `EthereumSigner`, `EthereumAddress`, `SuiSigner`, `SuiAddress`.
//! `EthereumSignerFfi`/`EthereumAddressFfi` and `SuiSignerFfi`/
//! `SuiAddressFfi` here are the Rust-side primitives-based
//! implementations that back the Swift `EthereumSigner`/`EthereumAddress`
//! and `SuiSigner`/`SuiAddress` — operating on `PublicKeyFfi`/
//! `PrivateKeyFfi` rather than the Swift-only `Account` type, since `Account`
//! has no Rust representation. `SuiSignerFfi` covers address derivation
//! only, matching the Swift spec. Every other chain client remains
//! design-only.

mod ethereum_address;
mod ethereum_signer;
mod sui_address;
mod sui_signer;

pub use ethereum_address::EthereumAddressFfi;
pub use ethereum_signer::EthereumSignerFfi;
pub use sui_address::SuiAddressFfi;
pub use sui_signer::SuiSignerFfi;
