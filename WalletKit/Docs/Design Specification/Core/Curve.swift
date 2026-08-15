//
//  Curve.swift
//  WalletKit
//
//  DESIGN SPEC — not generated code. See Walletkit/Docs/Overview.md for
//  module-level notes and architecture.
//

/// Elliptic curve used for a given key. Chain clients added later select
/// the curve implicitly via `Blockchain`; it's exposed here because both
/// key management and any future chain client need to reason about it.
public enum Curve: Equatable, CaseIterable {
    case secp256k1
    case secp256r1
    case ed25519
}
