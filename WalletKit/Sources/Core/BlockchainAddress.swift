//
//  BlockchainAddress.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 16/08/2026.
//

import Foundation

/// A validated, chain-specific address (e.g. ``EthereumAddress``,
/// ``SuiAddress``).
public protocol BlockchainAddress: Equatable {
    /// The chain's canonical string encoding of this address (e.g.
    /// EIP-55 checksummed hex for Ethereum).
    var string: String { get }

    /// The address's raw byte encoding.
    var rawBytes: Data { get }

    /// Parses and validates `string` as an address for this chain.
    ///
    /// - Parameter string: The address string to parse.
    init(string: String) throws

    /// Wraps `rawBytes` as an address for this chain.
    ///
    /// - Parameter rawBytes: The raw address bytes.
    init(rawBytes: Data) throws
}

/// Derives addresses and signs transactions for a specific blockchain.
public protocol Signer {
    /// The chain-specific address type this signer produces.
    associatedtype Address: BlockchainAddress

    /// The blockchain (and any chain-specific configuration, like an EVM
    /// chain ID) this signer is scoped to.
    var blockchain: Blockchain { get }

    /// Derives the address for `account`.
    ///
    /// - Parameter account: The account to derive the address for.
    /// - Returns: The account's chain-specific address.
    func address(for account: Account) throws -> Address

    /// Signs `transaction` with `account`'s key.
    ///
    /// - Parameters:
    ///   - transaction: The chain-specific unsigned transaction encoding
    ///     to sign.
    ///   - account: The account whose key should sign.
    /// - Returns: The chain-specific signed transaction encoding.
    func sign(transaction: Data, account: Account) async throws -> Data
}

/// Signs transactions by delegating the actual signature to a connected
/// hardware device, in the device's own transaction format rather than a
/// signer's raw `Data` blobs.
public protocol HardwareSigner {
    /// The chain-specific unsigned transaction type this signer accepts.
    associatedtype UnsignedTransaction

    /// The chain-specific signed transaction type this signer produces.
    associatedtype SignedTransaction

    /// Signs `transaction` with `account`'s key on `device`.
    ///
    /// - Parameters:
    ///   - transaction: The unsigned transaction to sign.
    ///   - account: The account whose key should sign.
    ///   - device: The hardware device to sign with.
    /// - Returns: The signed transaction.
    func sign(
        _ transaction: UnsignedTransaction,
        account: Account,
        device: HardwareDevice
    ) async throws -> SignedTransaction
}
