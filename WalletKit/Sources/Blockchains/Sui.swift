//
//  Sui.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 16/08/2026.
//

import Foundation

/// A validated Sui address (32 raw bytes) — the Blake2b-256 digest of a
/// one-byte scheme flag followed by the account's public key bytes.
/// Backed by ``SuiAddressFfi``.
public struct SuiAddress: BlockchainAddress {
    let raw: SuiAddressFfi

    init(raw: SuiAddressFfi) {
        self.raw = raw
    }

    /// The `0x`-prefixed, all-lowercase hex encoding of this address.
    public var string: String { raw.string() }

    /// The raw 32-byte address.
    public var rawBytes: Data { raw.rawBytes() }

    /// Parses `string` as a Sui address: `0x`-prefixed, 64 hex characters.
    /// Unlike Ethereum, Sui defines no checksum, so casing is never
    /// validated.
    ///
    /// - Parameter string: The address string to parse.
    /// - Throws: ``WalletKitError/invalidAddress(reason:)`` for a missing
    ///   `0x` prefix, wrong length, or non-hex characters.
    public init(string: String) throws {
        raw = try remappingWalletKitError { try SuiAddressFfi.fromString(string: string) }
    }

    /// Wraps `rawBytes` as a Sui address.
    ///
    /// - Parameter rawBytes: The raw address bytes.
    /// - Throws: ``WalletKitError/invalidAddress(reason:)`` if
    ///   `rawBytes.count != 32`.
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

    /// The blockchain this signer is scoped to — `.sui(curve)`.
    public var blockchain: Blockchain { .sui(curve) }

    /// Creates a signer scoped to `curve`.
    ///
    /// - Parameter curve: Which signature scheme this signer's accounts
    ///   use. Defaults to `.ed25519`, Sui's standard scheme.
    public init(curve: Curve = .ed25519) {
        self.curve = curve
        raw = SuiSignerFfi(curve: curve)
    }

    /// Derives the Sui address for `account`'s public key.
    ///
    /// - Parameter account: The account to derive the address for.
    /// - Returns: The account's Sui address.
    /// - Throws: ``WalletKitError/unsupportedCurve(curve:)`` if
    ///   `account.curve` doesn't match ``curve``.
    public func address(for account: Account) throws -> SuiAddress {
        try address(for: account.publicKey)
    }

    /// Derives the Sui address for `publicKey`: the Blake2b-256 hash of a
    /// one-byte scheme flag followed by `publicKey`'s raw bytes, with no
    /// truncation.
    ///
    /// - Parameter publicKey: The public key to derive the address for.
    /// - Returns: The corresponding Sui address.
    /// - Throws: ``WalletKitError/unsupportedCurve(curve:)`` if
    ///   `publicKey.curve != curve` — an account derived for one scheme
    ///   can't produce an address tagged with a different one, since
    ///   ``curve`` is what selects the flag byte.
    public func address(for publicKey: PublicKey) throws -> SuiAddress {
        try remappingWalletKitError { SuiAddress(raw: try raw.address(publicKey: publicKey.raw)) }
    }

    /// Not yet implemented — `Account` doesn't currently carry (or expose
    /// a way to recover) the private key material a software signature
    /// needs. Always throws.
    ///
    /// - Parameters:
    ///   - transaction: Unused.
    ///   - account: Unused.
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
    /// - Parameters:
    ///   - transaction: The raw BCS-encoded `TransactionData` bytes to
    ///     sign.
    ///   - privateKey: The key to sign with; must match ``curve``.
    /// - Returns: Sui's serialized signature, ready to broadcast alongside
    ///   `transaction`.
    /// - Throws: ``WalletKitError/unsupportedCurve(curve:)`` if
    ///   `privateKey.curve != curve`.
    public func sign(transaction: Data, privateKey: PrivateKey) async throws -> Data {
        try remappingWalletKitError { try raw.sign(transactionData: transaction, privateKey: privateKey.raw) }
    }
}
