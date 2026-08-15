//! `Curve`: the elliptic curve a key/derivation scheme is based on.

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum Curve {
    Secp256k1,
    Ed25519,
}

impl Curve {
    pub const ALL: [Curve; 2] = [Curve::Secp256k1, Curve::Ed25519];
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn curve_all_cases_are_distinct() {
        assert_eq!(Curve::ALL.len(), 2);
        assert_ne!(Curve::Secp256k1, Curve::Ed25519);
    }
}
