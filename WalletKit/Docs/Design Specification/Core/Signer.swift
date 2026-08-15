//
//  Signer.swift
//  WalletKit
//
//  DESIGN SPEC — not generated code. See Walletkit/Docs/Overview.md for
//  module-level notes and architecture.
//

import Foundation

/// Common protocol every chain-specific client conforms to (e.g.
/// `EthereumSigner`, `SuiSigner`), so address derivation and signing
/// share one shape across chains regardless of which one a caller is
/// working with.
public protocol Signer {
    associatedtype Address: BlockchainAddress

    var blockchain: Blockchain { get }

    /// Works identically for software- and hardware-sourced accounts.
    func address(for account: Account) async throws -> Address

    /// Signs `transaction` — already serialized into this chain's
    /// wire/broadcast format (e.g. RLP for Ethereum) by the caller — using
    /// `account`'s key, returning the signed transaction bytes ready to
    /// broadcast. A single shared signature across software- and
    /// hardware-sourced accounts (dispatched on `account.source`), unlike
    /// `HardwareSigner`'s per-(chain, vendor) associated types.
    ///
    /// Throws `.signingFailed` on curve-specific signing errors (software
    /// path), or `.deviceLocked`/`.deviceDisconnected`/
    /// `.userRejectedOnDevice` (hardware path, per `HardwareDevice`'s
    /// docs).
    ///
    /// Open question this spec doesn't resolve: taking `Data` in and out
    /// keeps this one shared signature, but a hardware device's trusted
    /// screen needs *structured* fields to decode and display what it's
    /// signing (see `HardwareSigner`'s docs for why a shared typed
    /// signature doesn't work across vendors) — a device can't show a
    /// meaningful confirmation from opaque serialized bytes alone. A
    /// hardware-backed `sign(transaction:account:)` implementation will
    /// likely need to parse `transaction` back into the chain's structured
    /// fields internally before calling into `HardwareSigner`/the
    /// device; this method doesn't remove that complexity, it only gives
    /// callers one entry point regardless of `account.source`.
    func sign(transaction: Data, account: Account) async throws -> Data
}
