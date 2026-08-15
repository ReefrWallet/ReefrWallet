//! `DerivationScheme`: the HD derivation scheme paired with a given curve.

use crate::common::Curve;

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum DerivationScheme {
    Bip32,
    Slip0010,
}

impl DerivationScheme {
    pub fn for_curve(curve: Curve) -> DerivationScheme {
        match curve {
            Curve::Secp256k1 => DerivationScheme::Bip32,
            Curve::Ed25519 => DerivationScheme::Slip0010,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn derivation_scheme_differs_by_curve() {
        assert_eq!(DerivationScheme::for_curve(Curve::Secp256k1), DerivationScheme::Bip32);
        assert_eq!(DerivationScheme::for_curve(Curve::Ed25519), DerivationScheme::Slip0010);
        assert_ne!(DerivationScheme::Bip32, DerivationScheme::Slip0010);
    }
}
