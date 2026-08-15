//
//  CoinType.swift
//  WalletKit
//
//  DESIGN SPEC — not generated code. See Walletkit/Docs/Overview.md for
//  module-level notes and architecture.
//

/// SLIP-44 coin type registry entry: a chain's curve plus its SLIP-44
/// index. This is the low-level building block `Blockchain` is defined in
/// terms of — application code should generally use `Blockchain` (in
/// `Blockchain.swift`) instead of reaching for `CoinType` directly.
///
/// Note: `cardano`'s real-world derivation is CIP-1852 / BIP32-Ed25519, a
/// variant of plain SLIP-0010. It's registered here for path/curve
/// bookkeeping now; full support lands alongside the Cardano chain client.
public struct CoinType: Equatable {
    public let slip44Index: UInt32
    public let curve: Curve
    public let identifier: String // e.g. "bitcoin", "ethereum"

    public init(slip44Index: UInt32, curve: Curve, identifier: String) {
        self.slip44Index = slip44Index
        self.curve = curve
        self.identifier = identifier
    }

    public static let bitcoin  = CoinType(slip44Index: 0,    curve: .secp256k1, identifier: "bitcoin")
    public static let ethereum = CoinType(slip44Index: 60,   curve: .secp256k1, identifier: "ethereum")
    public static let tron     = CoinType(slip44Index: 195,  curve: .secp256k1, identifier: "tron")
    public static let solana   = CoinType(slip44Index: 501,  curve: .ed25519,   identifier: "solana")
    public static let cardano  = CoinType(slip44Index: 1815, curve: .ed25519,   identifier: "cardano")
    public static let sui      = CoinType(slip44Index: 784,  curve: .ed25519,   identifier: "sui")
}
