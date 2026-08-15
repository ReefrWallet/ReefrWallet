//
//  ChainClient.swift
//  WalletKit
//
//  DESIGN SPEC — not generated code. See Walletkit/Docs/Overview.md for
//  module-level notes and architecture.
//

/// Marker protocol that chain-specific packages (WalletKitBitcoin,
/// WalletKitEthereum, WalletKitSolana, ...) will conform to once
/// introduced. Not backed by any Rust implementation yet — included here
/// so the extension point is visible from day one and current types
/// (`Account`, `Blockchain`) are already shaped to support it.
public protocol ChainClient {
    associatedtype Address

    var blockchain: Blockchain { get }

    /// Works identically for software- and hardware-sourced accounts.
    func deriveAddress(from account: Account) throws -> Address

    // Signing is intentionally not declared here — see `Account` and
    // `HardwareChainSigner` docs for why it can't be one shared signature
    // across software and every hardware vendor's wire protocol.
}
