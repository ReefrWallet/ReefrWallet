//
//  EthereumPKeySigner.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 17/08/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation
import WalletKitRust

/// A ``Signer`` backed directly by a software-held ``PrivateKey``, for
/// Ethereum. Backed by the `walletkit-ethereum`-equivalent Rust code in
/// `blockchain_clients/` (`EthereumSignerFfi`, Alloy-based).
public final class EthereumPKeySigner: Signer {
    public typealias Address = EthereumAddress

    /// The account this signer signs for.
    public let account: Account

    /// EVM chain ID this signer is scoped to (1 = mainnet, 11155111 =
    /// Sepolia, ...) — the value carried by `Blockchain.ethereum(_:)`.
    /// ``sign(transaction:)`` rejects a transaction whose embedded EIP-155
    /// chain ID doesn't match this.
    public let chainId: UInt64

    private let privateKey: PrivateKey
    private let raw: EthereumSignerFfi

    /// Creates a signer for `privateKey`, scoped to `chainId`.
    ///
    /// - Parameters:
    ///   - chainId: The EVM chain ID this signer should operate on.
    ///     Defaults to `1` (Ethereum mainnet).
    ///   - privateKey: The secp256k1 key to sign with.
    ///   - derivationPath: The derivation path `privateKey` was derived at
    ///     (or, for an externally imported key, the path it should be
    ///     treated as belonging to).
    /// - Throws: ``WalletKitError/unsupportedCurve(curve:)`` if
    ///   `privateKey.curve` isn't secp256k1.
    public init(chainId: UInt64 = 1, privateKey: PrivateKey, derivationPath: DerivationPath) throws {
        guard privateKey.curve == .secp256k1 else {
            throw WalletKitError.unsupportedCurve(curve: privateKey.curve)
        }
        self.chainId = chainId
        self.privateKey = privateKey
        raw = EthereumSignerFfi(chainId: chainId)
        account = Account(
            blockchain: .ethereum(chainId),
            derivationPath: derivationPath,
            curve: .secp256k1,
            source: .software,
            publicKey: privateKey.publicKey
        )
    }

    /// Derives the Ethereum address for ``account``'s public key.
    ///
    /// - Returns: The account's Ethereum address.
    public func address() throws -> EthereumAddress {
        try EthereumAddress(publicKey: account.publicKey)
    }

    /// Signs `transaction` — the RLP-encoded EIP-155 signing data described
    /// in `EthereumSigner`'s design spec — with ``account``'s key,
    /// returning the RLP-encoded signed transaction.
    ///
    /// - Parameter transaction: The 9-field EIP-155 RLP-encoded
    ///   `[nonce, gasPrice, gasLimit, to, value, data, chainId, 0, 0]`
    ///   unsigned transaction blob.
    /// - Returns: The RLP-encoded signed transaction
    ///   `[nonce, gasPrice, gasLimit, to, value, data, v, r, s]`, ready to
    ///   broadcast.
    /// - Throws: ``WalletKitError/signingFailed(reason:)`` if `transaction`
    ///   isn't well-formed 9-field EIP-155 RLP or its embedded chain ID
    ///   doesn't match ``chainId``.
    public func sign(transaction: Data) async throws -> Data {
        try remappingWalletKitError { try raw.sign(signingData: transaction, privateKey: privateKey.raw) }
    }
}
