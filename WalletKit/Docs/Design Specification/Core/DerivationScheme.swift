//
//  DerivationScheme.swift
//  WalletKit
//
//  DESIGN SPEC — not generated code. See Walletkit/Docs/Overview.md for
//  module-level notes and architecture.
//

/// Which hierarchical derivation scheme produced/derives an `ExtendedKey`.
/// Informational — derived automatically from `Curve`, exposed for
/// debugging/UI (e.g. showing "BIP32" vs "SLIP-0010" in a details view).
public enum DerivationScheme: Equatable {
    case bip32      // secp256k1 chains
    case slip0010   // ed25519 chains
}
