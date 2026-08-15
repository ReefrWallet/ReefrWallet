//! Blockchain-client extension points. See
//! `Walletkit/Docs/Design Specification/Clients/` for the target Swift
//! shape: `BlockchainClient`, `BlockchainAddress`, `HardwareSigner`,
//! `EthereumClient`, `EthereumAddress`. `EthereumClientFfi`/
//! `EthereumAddressFfi` here are the Rust-side primitives-based
//! implementations that back the (not yet written) Swift
//! `EthereumClient`/`EthereumAddress` — operating on `PublicKeyFfi`/
//! `PrivateKeyFfi` rather than the Swift-only `Account` type, since `Account`
//! has no Rust representation. Every other chain client remains design-only.

mod ethereum_address;
mod ethereum_client;

pub use ethereum_address::EthereumAddressFfi;
pub use ethereum_client::EthereumClientFfi;
