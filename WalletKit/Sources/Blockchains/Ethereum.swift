//
//  Ethereum.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 16/08/2026.
//

import Foundation

public struct EthereumAddress: BlockchainAddress {
    let raw: EthereumAddressFfi

    init(raw: EthereumAddressFfi) {
        self.raw = raw
    }

    public var string: String { raw.string() }
    public var rawBytes: Data { raw.rawBytes() }

    /// Ethereum-specific alias for `string`, for call sites that already
    /// know they're holding an `EthereumAddress` rather than an
    /// `any BlockchainAddress`.
    public var checksummed: String { string }

    public init(string: String) throws {
        raw = try remappingWalletKitError { try EthereumAddressFfi.fromString(string: string) }
    }

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

    public var blockchain: Blockchain { .ethereum(chainId) }

    public init(chainId: UInt64 = 1) {
        self.chainId = chainId
        raw = EthereumSignerFfi(chainId: chainId)
    }

    public func address(for account: Account) throws -> EthereumAddress {
        try address(for: account.publicKey)
    }

    public func address(for publicKey: PublicKey) throws -> EthereumAddress {
        try remappingWalletKitError { EthereumAddress(raw: try raw.address(publicKey: publicKey.raw)) }
    }

    public func sign(transaction: Data, account: Account) async throws -> Data {
        throw WalletKitError.internalError(
            message: "EthereumSigner.sign(transaction:account:) needs Account to expose its signing key, "
                + "which isn't wired up yet — use sign(transaction:privateKey:) instead"
        )
    }

    /// Signs `transaction` — the RLP-encoded EIP-155 signing data described
    /// in `EthereumSigner`'s design spec — with `privateKey` directly,
    /// returning the RLP-encoded signed transaction.
    public func sign(transaction: Data, privateKey: PrivateKey) async throws -> Data {
        try remappingWalletKitError { try raw.sign(signingData: transaction, privateKey: privateKey.raw) }
    }
}
