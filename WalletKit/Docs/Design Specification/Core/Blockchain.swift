//
//  Blockchain.swift
//  WalletKit
//
//  DESIGN SPEC — not generated code. See Walletkit/Docs/Overview.md for
//  module-level notes and architecture.
//

/// A specific chain WalletKit can derive keys and addresses for. This is
/// the identifier `Account`, `KeyProvider`, and `ChainClient` are built
/// around — callers select `.bitcoin`, `.ethereum`, etc. rather than
/// assembling a `CoinType` and a derivation path by hand.
///
/// `Blockchain` maps to a `CoinType` (the raw SLIP-44 registry entry: curve
/// + coin index) and knows how to produce that chain's standard derivation
/// path from it. `CoinType` stays around as the lower-level registry type
/// this is built on — application code should reach for `Blockchain` day
/// to day, not `CoinType` directly.
public struct Blockchain: Equatable {
    public let coinType: CoinType
    public let purpose: UInt32 // BIP44 purpose field; 44 for every chain here today

    public init(coinType: CoinType, purpose: UInt32 = 44) {
        self.coinType = coinType
        self.purpose = purpose
    }

    public var curve: Curve { coinType.curve }
    public var identifier: String { coinType.identifier }

    /// The standard `m/purpose'/coin_type'/account'/change/index` path for
    /// this chain.
    public func derivationPath(account: UInt32 = 0, change: UInt32 = 0, index: UInt32 = 0) -> DerivationPath {
        .bip44(purpose: purpose, coinType: coinType, account: account, change: change, index: index)
    }

    public static let bitcoin  = Blockchain(coinType: .bitcoin)
    public static let ethereum = Blockchain(coinType: .ethereum)
    public static let tron     = Blockchain(coinType: .tron)
    public static let solana   = Blockchain(coinType: .solana)
    public static let cardano  = Blockchain(coinType: .cardano)
    public static let sui      = Blockchain(coinType: .sui)
}
