//! Low-level, chain-agnostic types. See
//! `Walletkit/Docs/Design Specification/Core/` for the target shape:
//! `Curve`, `DerivationScheme`, `Wordlist`, `MnemonicWordCount`,
//! `Blockchain`, `DerivationPath`.
//!
//! Named `common` rather than `core` because `core` is reserved by the
//! Rust standard library. These are plain data types crossing the UniFFI
//! boundary as Records/Enums; the ergonomic computed properties/statics
//! the Swift design spec describes (`Blockchain.ethereum`,
//! `DerivationPath(string:)`, ...) are added on the Swift side, since
//! they're pure data-shuffling with no cryptography involved.

mod blockchain;
mod curve;
mod derivation_path;
mod derivation_scheme;
mod mnemonic_word_count;
mod segment;
mod wordlist;

pub use blockchain::Blockchain;
pub use curve::Curve;
pub use derivation_path::DerivationPath;
pub use derivation_scheme::DerivationScheme;
pub use mnemonic_word_count::MnemonicWordCount;
pub use segment::Segment;
pub use wordlist::Wordlist;
