//! `Blockchain`: a chain identifier, one case per supported chain. Carries
//! no derivation-path logic of its own — an `Account`'s curve and
//! derivation path are tracked directly on `Account` instead. Some cases
//! carry the extra configuration a `Signer` needs beyond the identifier
//! itself: `Ethereum` carries its EVM chain ID, `Sui` carries the
//! signature scheme its accounts use. See
//! `Walletkit/Docs/Design Specification/Core/Blockchain.swift`.

use crate::common::Curve;

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum Blockchain {
    Bitcoin,
    Ethereum(u64),
    Tron,
    Solana,
    Cardano,
    Sui(Curve),
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn blockchain_cases_are_distinct() {
        assert_ne!(Blockchain::Bitcoin, Blockchain::Ethereum(1));
    }

    #[test]
    fn ethereum_variants_compare_by_chain_id() {
        assert_eq!(Blockchain::Ethereum(1), Blockchain::Ethereum(1));
        assert_ne!(Blockchain::Ethereum(1), Blockchain::Ethereum(11_155_111));
    }

    #[test]
    fn sui_variants_compare_by_curve() {
        assert_eq!(Blockchain::Sui(Curve::Ed25519), Blockchain::Sui(Curve::Ed25519));
        assert_ne!(Blockchain::Sui(Curve::Ed25519), Blockchain::Sui(Curve::Secp256k1));
    }
}
