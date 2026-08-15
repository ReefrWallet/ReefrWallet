//
//  Blockchain.swift
//  WalletKit
//
//  DESIGN SPEC — not generated code. See Walletkit/Docs/Overview.md for
//  module-level notes and architecture.
//

public enum Blockchain: Equatable, CaseIterable {
    case bitcoin

    // parameter is EVM chain id
    case ethereum(UInt64)

    case tron
    case solana
    case cardano

    // Ed25519: m/44'/784'/0'/0'/0' (fully hardened)
    // ECDSA Secp256k1: m/54'/784'/0'/0/0 (first three levels hardened)
    // ECDSA Secp256r1: m/74'/784'/0'/0/0 (first three levels hardened)
    case sui(Curve)
}
