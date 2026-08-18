//
//  EthereumRPCClient.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 17/08/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation

/// Chainlink's `AggregatorV3Interface.latestRoundData()` return values —
/// the worked example for reading an on-chain oracle.
public struct ChainlinkRoundData {
    public let roundId: BigUInt
    public let answer: BigInt
    public let startedAt: BigUInt
    public let updatedAt: BigUInt
    public let answeredInRound: BigUInt
}

/// A client for an Ethereum JSON-RPC node — native-token balance,
/// arbitrary read-only contract calls, and broadcasting an already-signed
/// transaction. Pairs with ``EthereumPKeySigner``/``EthereumTrezorSigner``,
/// which produce the signed transaction bytes ``broadcast(_:)`` sends;
/// this client builds no transactions of its own.
public struct EthereumRPCClient {
    /// The EVM chain ID this client's endpoint is expected to serve —
    /// descriptive only. Unlike signing, reading a balance or broadcasting
    /// to the wrong network is a configuration/UX concern, not a replay-
    /// protection one, so this isn't enforced against responses.
    public let chainId: UInt64

    private let rpc: JSONRPCClient

    /// Creates a client for the node at `endpoint`.
    ///
    /// - Parameters:
    ///   - endpoint: The node's JSON-RPC HTTPS endpoint.
    ///   - chainId: The EVM chain ID this endpoint is expected to serve.
    ///     Defaults to `1` (Ethereum mainnet).
    ///   - session: The `URLSession` to issue requests on. Defaults to
    ///     `.shared`.
    public init(endpoint: URL, chainId: UInt64 = 1, session: URLSession = .shared) {
        self.chainId = chainId
        rpc = JSONRPCClient(endpoint: endpoint, session: session)
    }

    /// Reads `address`'s native-token (ETH) balance, in wei.
    ///
    /// - Parameter address: The address to read the balance of.
    /// - Returns: The balance, in wei.
    /// - Throws: ``BlockchainClientError`` on a transport, RPC, or
    ///   decoding failure.
    public func nativeBalance(of address: EthereumAddress) async throws -> BigUInt {
        let hex: String = try await rpc.call(method: "eth_getBalance", params: [address.string, "latest"])

        // `eth_getBalance` returns Ethereum's "Quantity" hex encoding —
        // minimal digits, no leading zeros, so (unlike "Data" hex —
        // addresses, calldata, raw tx — which is always byte-aligned) an
        // odd digit count is valid (e.g. "0x1" for 1 wei). Parsed as a
        // plain hex integer, not through `Data(hexString:)`.
        let body = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex

        guard let balance = BigUInt(body, radix: 16) else {
            throw BlockchainClientError.decodingFailed(reason: "invalid quantity hex: \(hex)")
        }

        return balance
    }

    /// Executes a read-only contract call against `address` — the
    /// general "execute a smart contract" entry point. ``erc20Balance``
    /// and ``latestRoundData`` are two worked examples built on this; a
    /// caller with a different contract computes its own call data via
    /// ``EthereumABI`` and calls this directly.
    ///
    /// - Parameters:
    ///   - address: The contract address to call.
    ///   - data: The ABI-encoded call data (selector + parameters).
    /// - Returns: The raw return data.
    /// - Throws: ``BlockchainClientError`` on a transport, RPC, or
    ///   decoding failure.
    public func call(to address: EthereumAddress, data: Data) async throws -> Data {
        let params = EthCallParams(to: address.string, data: data.hexEncoded)
        let hex: String = try await rpc.call(method: "eth_call", params: params)
        return try Data(hexString: hex)
    }

    /// Reads an ERC-20 `token`'s balance for `owner` — `balanceOf(address)`.
    ///
    /// - Parameters:
    ///   - token: The ERC-20 contract address.
    ///   - owner: The account to read the balance of.
    /// - Returns: The balance, in the token's smallest unit.
    /// - Throws: ``BlockchainClientError`` on a transport, RPC, or
    ///   decoding failure.
    public func erc20Balance(
        token: EthereumAddress,
        owner: EthereumAddress
    ) async throws -> BigUInt {
        let data = EthereumABI.encodeCall(
            selector: EthereumABI.selector("balanceOf(address)"),
            parameters: [.address(owner)]
        )

        let result = try await call(to: token, data: data)

        guard let word = EthereumABI.words(result).first else {
            throw BlockchainClientError.decodingFailed(reason: "empty balanceOf(address) response")
        }

        return EthereumABI.decodeUInt256(word)
    }

    /// Reads a Chainlink price feed's latest round — `latestRoundData()`.
    ///
    /// - Parameter feed: The `AggregatorV3Interface`-conforming feed
    ///   contract address.
    /// - Returns: The feed's latest round data.
    /// - Throws: ``BlockchainClientError`` on a transport, RPC, or
    ///   decoding failure.
    public func latestRoundData(feed: EthereumAddress) async throws -> ChainlinkRoundData {
        let data = EthereumABI.encodeCall(selector: EthereumABI.selector("latestRoundData()"))
        let result = try await call(to: feed, data: data)
        let words = EthereumABI.words(result)

        guard words.count >= 5 else {
            throw BlockchainClientError.decodingFailed(reason: "expected 5 words, got \(words.count)")
        }

        return ChainlinkRoundData(
            roundId: EthereumABI.decodeUInt256(words[0]),
            answer: EthereumABI.decodeInt256(words[1]),
            startedAt: EthereumABI.decodeUInt256(words[2]),
            updatedAt: EthereumABI.decodeUInt256(words[3]),
            answeredInRound: EthereumABI.decodeUInt256(words[4])
        )
    }

    /// Broadcasts an already-signed transaction — `eth_sendRawTransaction`.
    ///
    /// - Parameter signedTransaction: The RLP-encoded signed transaction,
    ///   e.g. from ``EthereumPKeySigner/sign(transaction:)``.
    /// - Returns: The transaction hash.
    /// - Throws: ``BlockchainClientError`` on a transport, RPC, or
    ///   decoding failure.
    public func broadcast(_ signedTransaction: Data) async throws -> String {
        try await rpc.call(method: "eth_sendRawTransaction", params: [signedTransaction.hexEncoded])
    }
}

/// `eth_call`'s heterogeneous `[{to, data}, "latest"]` params — encoded
/// manually since the two elements aren't the same type.
private struct EthCallParams: Encodable {
    let to: String
    let data: String

    private struct CallObject: Encodable {
        let to: String
        let data: String
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(CallObject(to: to, data: data))
        try container.encode("latest")
    }
}
