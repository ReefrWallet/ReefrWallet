//
//  Ethereum.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 16/08/2026.
//

import Foundation

/// A validated Ethereum address (20 raw bytes), backed by
/// ``EthereumAddressFfi``.
public struct EthereumAddress: BlockchainAddress {
    let raw: EthereumAddressFfi

    init(raw: EthereumAddressFfi) {
        self.raw = raw
    }

    /// The EIP-55 mixed-case checksummed, `0x`-prefixed hex encoding of
    /// this address.
    public var string: String { raw.string() }

    /// The raw 20-byte address.
    public var rawBytes: Data { raw.rawBytes() }

    /// Ethereum-specific alias for ``string``, for call sites that already
    /// know they're holding an ``EthereumAddress`` rather than an
    /// `any BlockchainAddress`.
    public var checksummed: String { string }

    /// Parses and validates `string` as an Ethereum address — `0x`-prefixed,
    /// 40 hex characters, either all one case (no checksum to validate) or
    /// held to its EIP-55 mixed-case checksum.
    ///
    /// - Parameter string: The address string to parse.
    /// - Throws: ``WalletKitError/invalidAddress(reason:)`` for anything
    ///   else, including a mixed-case string with the wrong checksum.
    public init(string: String) throws {
        raw = try remappingWalletKitError { try EthereumAddressFfi.fromString(string: string) }
    }

    /// Wraps `rawBytes` as an Ethereum address.
    ///
    /// - Parameter rawBytes: The raw address bytes.
    /// - Throws: ``WalletKitError/invalidAddress(reason:)`` if
    ///   `rawBytes.count != 20`.
    public init(rawBytes: Data) throws {
        raw = try remappingWalletKitError { try EthereumAddressFfi(rawBytes: rawBytes) }
    }

    public static func == (lhs: EthereumAddress, rhs: EthereumAddress) -> Bool {
        lhs.rawBytes == rhs.rawBytes
    }
}

/// Concrete `Signer` conformer, backed by the
/// `walletkit-ethereum`-equivalent Rust code in `blockchain_clients/`
/// (`EthereumSignerFfi`, Alloy-based). `address(for:)` is fully wired up;
/// `sign(transaction:account:)` is not yet — `Account` doesn't currently
/// carry (or expose a way to recover) the private key material a software
/// signature needs, and hardware signing needs the `HardwareSigner` routing
/// described in `Signer`'s spec. Use
/// `sign(transaction:privateKey:)` directly with a key you've already
/// derived until that Account → signing-key lookup exists.
public final class EthereumSigner: Signer {
    public typealias Address = EthereumAddress

    /// EVM chain ID this signer is scoped to (1 = mainnet, 11155111 =
    /// Sepolia, ...) — the value carried by `Blockchain.ethereum(_:)`.
    /// `sign(transaction:account:)`/`sign(transaction:privateKey:)` reject
    /// a transaction whose embedded EIP-155 chain ID doesn't match this.
    public let chainId: UInt64
    let raw: EthereumSignerFfi

    /// The blockchain this signer is scoped to — `.ethereum(chainId)`.
    public var blockchain: Blockchain { .ethereum(chainId) }

    /// Creates a signer scoped to `chainId`.
    ///
    /// - Parameter chainId: The EVM chain ID this signer should operate on.
    ///   Defaults to `1` (Ethereum mainnet).
    public init(chainId: UInt64 = 1) {
        self.chainId = chainId
        raw = EthereumSignerFfi(chainId: chainId)
    }

    /// Derives the Ethereum address for `account`'s public key.
    ///
    /// - Parameter account: The account to derive the address for.
    /// - Returns: The account's Ethereum address.
    /// - Throws: ``WalletKitError/unsupportedCurve(curve:)`` if
    ///   `account.curve` isn't secp256k1.
    public func address(for account: Account) throws -> EthereumAddress {
        try address(for: account.publicKey)
    }

    /// Derives the Ethereum address for `publicKey` — the last 20 bytes of
    /// the Keccak-256 hash of its uncompressed public-key encoding.
    ///
    /// - Parameter publicKey: The public key to derive the address for.
    /// - Returns: The corresponding Ethereum address.
    /// - Throws: ``WalletKitError/unsupportedCurve(curve:)`` if
    ///   `publicKey.curve` isn't secp256k1 — there is no Ethereum address
    ///   for an ed25519 key.
    public func address(for publicKey: PublicKey) throws -> EthereumAddress {
        try remappingWalletKitError { EthereumAddress(raw: try raw.address(publicKey: publicKey.raw)) }
    }

    /// Not yet implemented — see the type-level discussion. Always throws.
    ///
    /// - Parameters:
    ///   - transaction: Unused.
    ///   - account: Unused.
    public func sign(transaction: Data, account: Account) async throws -> Data {
        throw WalletKitError.internalError(
            message: "EthereumSigner.sign(transaction:account:) needs Account to expose its signing key, "
                + "which isn't wired up yet — use sign(transaction:privateKey:) instead"
        )
    }

    /// Signs `transaction` — the RLP-encoded EIP-155 signing data described
    /// in `EthereumSigner`'s design spec — with `privateKey` directly,
    /// returning the RLP-encoded signed transaction.
    ///
    /// - Parameters:
    ///   - transaction: The 9-field EIP-155 RLP-encoded
    ///     `[nonce, gasPrice, gasLimit, to, value, data, chainId, 0, 0]`
    ///     unsigned transaction blob.
    ///   - privateKey: The secp256k1 key to sign with.
    /// - Returns: The RLP-encoded signed transaction
    ///   `[nonce, gasPrice, gasLimit, to, value, data, v, r, s]`, ready to
    ///   broadcast.
    /// - Throws: ``WalletKitError/unsupportedCurve(curve:)`` for a
    ///   non-secp256k1 key, or ``WalletKitError/signingFailed(reason:)``
    ///   if `transaction` isn't well-formed 9-field EIP-155 RLP or its
    ///   embedded chain ID doesn't match ``chainId``.
    public func sign(transaction: Data, privateKey: PrivateKey) async throws -> Data {
        try remappingWalletKitError { try raw.sign(signingData: transaction, privateKey: privateKey.raw) }
    }
}
