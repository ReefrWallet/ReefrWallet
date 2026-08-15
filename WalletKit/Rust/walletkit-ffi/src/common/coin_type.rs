//! `CoinType`: a SLIP-44 coin registry entry (curve + coin index + identifier).

use crate::common::Curve;

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CoinType {
    pub slip44_index: u32,
    pub curve: Curve,
    pub identifier: String,
}

impl CoinType {
    pub fn bitcoin() -> CoinType {
        CoinType { slip44_index: 0, curve: Curve::Secp256k1, identifier: "bitcoin".to_string() }
    }
    pub fn ethereum() -> CoinType {
        CoinType { slip44_index: 60, curve: Curve::Secp256k1, identifier: "ethereum".to_string() }
    }
    pub fn tron() -> CoinType {
        CoinType { slip44_index: 195, curve: Curve::Secp256k1, identifier: "tron".to_string() }
    }
    pub fn solana() -> CoinType {
        CoinType { slip44_index: 501, curve: Curve::Ed25519, identifier: "solana".to_string() }
    }
    pub fn cardano() -> CoinType {
        CoinType { slip44_index: 1815, curve: Curve::Ed25519, identifier: "cardano".to_string() }
    }
    pub fn sui() -> CoinType {
        CoinType { slip44_index: 784, curve: Curve::Ed25519, identifier: "sui".to_string() }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn coin_type_static_instances_carry_the_expected_fields() {
        assert_eq!(CoinType::bitcoin().slip44_index, 0);
        assert_eq!(CoinType::bitcoin().curve, Curve::Secp256k1);
        assert_eq!(CoinType::bitcoin().identifier, "bitcoin");
        assert_ne!(CoinType::bitcoin(), CoinType::ethereum());
    }
}
