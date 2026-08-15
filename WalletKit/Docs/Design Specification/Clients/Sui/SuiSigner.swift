//
//  SuiSigner.swift
//  WalletKit
//
//  DESIGN SPEC — not generated code. See Walletkit/Docs/Overview.md for
//  module-level notes and architecture.
//

import Foundation

/// Concrete `Signer` conformer, backed by a dedicated `walletkit-sui`
/// Rust crate (see "Crate layout" in Overview.md).
public final class SuiSigner: Signer {
    public typealias Address = SuiAddress

    /// Which signature scheme this signer's accounts use — the `Curve`
    /// carried by `Blockchain.sui(_:)`. Unlike Ethereum, where address
    /// encoding is curve-independent, Sui encodes *which* scheme produced
    /// a key directly into the address (see `address(for:)`), so an
    /// account's curve has to match the scheme this signer is configured
    /// for. `.ed25519` is Sui's standard/default scheme; `.secp256k1`
    /// accounts also exist.
    public let curve: Curve

    public var blockchain: Blockchain { .sui(curve) }

    /// - Parameter curve: the signature scheme this signer expects its
    ///   accounts to use. Defaults to `.ed25519`.
    public init(curve: Curve = .ed25519) {
        self.curve = curve
    }

    /// Derives the `SuiAddress` for `account`.
    ///
    /// Algorithm (Blake2b-256, per Sui's flag-tagged address scheme):
    /// 1. Byte 0 is a flag identifying the signature scheme: `0x00` for
    ///    `.ed25519`, `0x01` for `.secp256k1`.
    /// 2. Followed by the account's raw public key bytes (32-byte raw
    ///    Ed25519, or 33-byte compressed secp256k1).
    /// 3. Blake2b-256 hash of `flag || publicKey` — the full 32-byte
    ///    digest is the address's raw bytes; unlike `EthereumSigner`,
    ///    there's no truncation.
    ///
    /// Throws `.unsupportedCurve` if `account.curve != self.curve` — an
    /// account derived for one scheme can't produce an address tagged
    /// with a different one, and `self.curve` (from `Blockchain.sui(_:)`)
    /// is what selects the flag byte.
    public func address(for account: Account) throws -> SuiAddress {
        fatalError("spec only")
    }

    /// Signs a BCS-encoded, intent-prefixed Sui transaction — Sui wraps
    /// the raw `TransactionData` bytes with a 3-byte scope/version/app-id
    /// "intent" prefix before hashing and signing — returning the
    /// signature bytes ready to broadcast alongside the transaction.
    public func sign(transaction: Data, account: Account) async throws -> Data {
        fatalError("spec only")
    }
}
