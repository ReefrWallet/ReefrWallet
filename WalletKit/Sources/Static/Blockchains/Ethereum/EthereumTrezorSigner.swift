//
//  EthereumTrezorSigner.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 17/08/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation
import WalletKitRust

/// A ``Signer`` backed by a connected Trezor ``HardwareDevice``, for
/// Ethereum. The device signs; this type only handles decoding the
/// caller-supplied EIP-155 signing data into the structured fields the
/// device's trusted screen displays (``signTx(from:)``) and re-assembling
/// the device's returned signature into a broadcastable transaction
/// (``signedTransaction(_:signature:)``) — both real, Rust-backed
/// operations, shared with ``EthereumPKeySigner``'s software path via
/// `EthereumSignerFfi`. The device conversation itself needs the
/// `walletkit-trezor` transport, which isn't implemented yet (see
/// `Docs/Overview.md`'s "Hardware wallet support"), so ``sign(transaction:)``
/// throws at that one step.
public final class EthereumTrezorSigner: Signer {
    public typealias Address = EthereumAddress

    /// The account this signer signs for.
    public let account: Account

    /// EVM chain ID this signer is scoped to (1 = mainnet, 11155111 =
    /// Sepolia, ...) — the value carried by `Blockchain.ethereum(_:)`.
    public let chainId: UInt64

    private let device: HardwareDevice
    private let raw: EthereumSignerFfi

    /// Creates a signer scoped to `chainId`, reading the public key at
    /// `derivationPath` off `device` to build ``account``.
    ///
    /// - Parameters:
    ///   - chainId: The EVM chain ID this signer should operate on.
    ///     Defaults to `1` (Ethereum mainnet).
    ///   - device: The connected Trezor to sign with.
    ///   - derivationPath: The derivation path to read the account's
    ///     public key at.
    /// - Throws: ``WalletKitError/deviceDisconnected`` if `device` isn't
    ///   connected.
    public init(chainId: UInt64 = 1, device: HardwareDevice, derivationPath: DerivationPath) async throws {
        let publicKey = try await device.publicKey(path: derivationPath, curve: .secp256k1)
        self.chainId = chainId
        self.device = device
        raw = EthereumSignerFfi(chainId: chainId)
        account = Account(
            blockchain: .ethereum(chainId),
            derivationPath: derivationPath,
            curve: .secp256k1,
            source: device.source,
            publicKey: publicKey
        )
    }

    /// Derives the Ethereum address for ``account``'s public key.
    public func address() throws -> EthereumAddress {
        try EthereumAddress(publicKey: account.publicKey)
    }

    /// Decodes `transaction` into the structured fields Trezor's
    /// `EthereumSignTx` message carries, for the device's trusted screen to
    /// display.
    ///
    /// - Parameter transaction: The 9-field EIP-155 RLP-encoded unsigned
    ///   transaction blob.
    /// - Throws: ``WalletKitError/signingFailed(reason:)`` if `transaction`
    ///   isn't well-formed 9-field EIP-155 RLP or its embedded chain ID
    ///   doesn't match ``chainId``.
    public func signTx(from transaction: Data) throws -> EthereumSignTx {
        try remappingWalletKitError { try EthereumSignTx(raw: try raw.decodeSigningData(signingData: transaction)) }
    }

    /// Assembles `transaction` and a device-produced `signature` into a
    /// broadcastable signed transaction.
    ///
    /// - Parameters:
    ///   - transaction: The same unsigned transaction blob passed to
    ///     ``signTx(from:)``.
    ///   - signature: The signature the device returned for it.
    /// - Returns: The RLP-encoded signed transaction, ready to broadcast.
    /// - Throws: ``WalletKitError/signingFailed(reason:)`` if `signature`
    ///   doesn't match ``chainId``'s expected EIP-155 `v`, or its `r`/`s`
    ///   aren't 32 bytes each.
    public func signedTransaction(_ transaction: Data, signature: EthereumSignature) throws -> Data {
        try remappingWalletKitError { try raw.encodeSigned(signingData: transaction, signature: signature.raw) }
    }

    /// Signs `transaction` on the connected Trezor.
    ///
    /// - Note: The decode (``signTx(from:)``) and re-encode
    ///   (``signedTransaction(_:signature:)``) halves are fully
    ///   implemented; only the device conversation itself is missing,
    ///   since no Trezor transport exists yet.
    public func sign(transaction: Data) async throws -> Data {
        _ = try signTx(from: transaction)
        guard device.isConnected else {
            throw WalletKitError.deviceDisconnected
        }
        throw WalletKitError.transportUnavailable(
            reason: "Trezor Ethereum signing needs the walletkit-trezor transport, which isn't implemented yet"
        )
    }
}
