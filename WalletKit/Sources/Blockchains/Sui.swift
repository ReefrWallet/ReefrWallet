//
//  Sui.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 16/08/2026.
//

import Foundation

public struct SuiAddress: BlockchainAddress {
    let raw: SuiAddressFfi

    init(raw: SuiAddressFfi) {
        self.raw = raw
    }

    public var string: String { raw.string() }
    public var rawBytes: Data { raw.rawBytes() }

    public init(string: String) throws {
        raw = try remappingWalletKitError { try SuiAddressFfi.fromString(string: string) }
    }

    public init(rawBytes: Data) throws {
        raw = try remappingWalletKitError { try SuiAddressFfi(rawBytes: rawBytes) }
    }

    public static func == (lhs: SuiAddress, rhs: SuiAddress) -> Bool {
        lhs.rawBytes == rhs.rawBytes
    }
}

/// Concrete `Signer` conformer for Sui, backed by `SuiSignerFfi`
/// (blake2-based).
public final class SuiSigner: Signer {
    public typealias Address = SuiAddress

    /// Which signature scheme this signer's accounts use — the `Curve`
    /// carried by `Blockchain.sui(_:)`. Defaults to `.ed25519`, Sui's
    /// standard scheme.
    public let curve: Curve
    let raw: SuiSignerFfi

    public var blockchain: Blockchain { .sui(curve) }

    public init(curve: Curve = .ed25519) {
        self.curve = curve
        raw = SuiSignerFfi(curve: curve)
    }

    public func address(for account: Account) throws -> SuiAddress {
        try address(for: account.publicKey)
    }

    public func address(for publicKey: PublicKey) throws -> SuiAddress {
        try remappingWalletKitError { SuiAddress(raw: try raw.address(publicKey: publicKey.raw)) }
    }

    public func sign(transaction: Data, account: Account) async throws -> Data {
        throw WalletKitError.internalError(
            message: "SuiSigner.sign(transaction:account:) needs Account to expose its signing key, "
                + "which isn't wired up yet — use sign(transaction:privateKey:) instead"
        )
    }

    /// Signs `transaction` — raw, un-intent-prefixed BCS-encoded
    /// `TransactionData` bytes for a Programmable Transaction Block (e.g.
    /// from `sui client ptb --serialize-unsigned-transaction`) — with
    /// `privateKey` directly, returning Sui's serialized signature
    /// (`flag || signature || public key`) ready to broadcast alongside
    /// `transaction`.
    ///
    /// Throws `.unsupportedCurve` if `privateKey.curve != self.curve`.
    public func sign(transaction: Data, privateKey: PrivateKey) async throws -> Data {
        try remappingWalletKitError { try raw.sign(transactionData: transaction, privateKey: privateKey.raw) }
    }
}
