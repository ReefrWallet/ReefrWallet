//! `Blockchain`: identified by its `CoinType`, plus the BIP44 purpose to
//! derive its standard account paths under.

use crate::common::{CoinType, Curve, DerivationPath};

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Blockchain {
    pub coin_type: CoinType,
    pub purpose: u32,
}

impl Blockchain {
    pub fn new(coin_type: CoinType, purpose: u32) -> Blockchain {
        Blockchain { coin_type, purpose }
    }

    pub fn bitcoin() -> Blockchain {
        Blockchain::new(CoinType::bitcoin(), 44)
    }
    pub fn ethereum() -> Blockchain {
        Blockchain::new(CoinType::ethereum(), 44)
    }
    pub fn tron() -> Blockchain {
        Blockchain::new(CoinType::tron(), 44)
    }
    pub fn solana() -> Blockchain {
        Blockchain::new(CoinType::solana(), 44)
    }
    pub fn cardano() -> Blockchain {
        Blockchain::new(CoinType::cardano(), 44)
    }
    pub fn sui() -> Blockchain {
        Blockchain::new(CoinType::sui(), 44)
    }

    pub fn curve(&self) -> Curve {
        self.coin_type.curve
    }

    pub fn identifier(&self) -> String {
        self.coin_type.identifier.clone()
    }

    pub fn derivation_path(&self, account: u32, change: u32, index: u32) -> DerivationPath {
        DerivationPath::bip44(self.purpose, &self.coin_type, account, change, index)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_blockchain_defaults_purpose_to_44() {
        for blockchain in [
            Blockchain::bitcoin(),
            Blockchain::ethereum(),
            Blockchain::tron(),
            Blockchain::solana(),
            Blockchain::cardano(),
            Blockchain::sui(),
        ] {
            assert_eq!(blockchain.purpose, 44);
        }
    }

    #[test]
    fn blockchain_curve_is_forwarded_from_coin_type() {
        assert_eq!(Blockchain::ethereum().curve(), Curve::Secp256k1);
        assert_eq!(Blockchain::solana().curve(), Curve::Ed25519);
    }

    #[test]
    fn blockchain_identifier_is_forwarded_from_coin_type() {
        assert_eq!(Blockchain::bitcoin().identifier(), "bitcoin");
    }

    #[test]
    fn blockchain_derivation_path_uses_bip44_shape() {
        let path = Blockchain::ethereum().derivation_path(0, 0, 0);
        assert_eq!(path, DerivationPath::bip44(44, &CoinType::ethereum(), 0, 0, 0));
    }

    #[test]
    fn custom_purpose_overrides_default() {
        let blockchain = Blockchain::new(CoinType::bitcoin(), 49);
        assert_eq!(blockchain.purpose, 49);
    }
}
