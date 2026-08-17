//! Blockchain-client extension points. See
//! `Walletkit/Docs/Design Specification/Clients/` for the target Swift
//! shape: `Signer`, `BlockchainAddress`, `EthereumPKeySigner`,
//! `EthereumTrezorSigner`, `EthereumAddress`, `SuiPKeySigner`, `SuiAddress`.
//! `EthereumSignerFfi`/`EthereumAddressFfi` and `SuiSignerFfi`/
//! `SuiAddressFfi` here are the Rust-side primitives-based
//! implementations that back those Swift signer/address types —
//! operating on `PublicKeyFfi`/`PrivateKeyFfi` rather than the Swift-only
//! `Account` type, since `Account` has no Rust representation.
//! `EthereumSignerFfi` additionally exposes `decode_signing_data`/
//! `signature`/`encode_signed` as the seam a hardware-backed signer (no
//! private key, a device instead) composes to reach the same signed
//! output as the software `sign` path. `SuiSignerFfi` covers address
//! derivation only, matching the Swift spec. Every other chain client
//! remains design-only.

mod ethereum_address;
mod ethereum_signer;
mod sui_address;
mod sui_signer;

pub use ethereum_address::EthereumAddressFfi;
pub use ethereum_signer::EthereumSignerFfi;
pub use sui_address::SuiAddressFfi;
pub use sui_signer::SuiSignerFfi;
