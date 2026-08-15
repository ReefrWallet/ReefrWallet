//! `SeedFfi`: a 64-byte BIP39 seed, and the entry point for master-key
//! derivation. See `Walletkit/Docs/Design Specification/Keys/SeedFfi.swift`.

use std::sync::Arc;

use zeroize::Zeroizing;

use crate::common::Curve;
use crate::keys::extended_key::ExtendedKeyFfi;

#[derive(uniffi::Object)]
pub struct SeedFfi {
    raw_bytes: Zeroizing<[u8; 64]>,
}

impl std::fmt::Debug for SeedFfi {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SeedFfi").finish_non_exhaustive()
    }
}

impl SeedFfi {
    pub(crate) fn new(raw_bytes: [u8; 64]) -> SeedFfi {
        SeedFfi {
            raw_bytes: Zeroizing::new(raw_bytes),
        }
    }
}

#[uniffi::export]
impl SeedFfi {
    /// Derives the master `ExtendedKeyFfi` for the requested curve/scheme.
    pub fn master_key(&self, curve: Curve) -> Arc<ExtendedKeyFfi> {
        Arc::new(ExtendedKeyFfi::master(curve, self.raw_bytes.as_slice()))
    }

    /// Raw 64-byte seed. Sensitive — treat as short-lived, don't log it.
    pub fn export_raw(&self) -> Vec<u8> {
        self.raw_bytes.to_vec()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::common::{MnemonicWordCount, Wordlist};
    use crate::keys::MnemonicFfi;

    fn seed() -> Arc<SeedFfi> {
        MnemonicFfi::generate(MnemonicWordCount::Words24, Wordlist::English).to_seed("".to_string())
    }

    #[test]
    fn export_raw_produces_64_bytes() {
        assert_eq!(seed().export_raw().len(), 64);
    }

    #[test]
    fn master_key_supports_secp256k1() {
        let key = seed().master_key(Curve::Secp256k1);
        assert_eq!(key.curve(), Curve::Secp256k1);
        assert_eq!(key.depth(), 0);
    }

    #[test]
    fn master_key_supports_ed25519() {
        let key = seed().master_key(Curve::Ed25519);
        assert_eq!(key.curve(), Curve::Ed25519);
        assert_eq!(key.depth(), 0);
    }
}
