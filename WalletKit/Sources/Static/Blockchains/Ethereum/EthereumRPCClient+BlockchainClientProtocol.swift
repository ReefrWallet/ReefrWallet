//
//  EthereumRPCClient+BlockchainClientProtocol.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 20/08/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt

/// ``BlockchainClientProtocol`` conformance for ``EthereumRPCClient``.
///
/// `Address` is inferred as ``EthereumAddress`` from the method signatures.
/// The `token` parameter in ``getBalance(_:token:)`` and ``getTokenInfo(_:)``
/// remains a `String` — an ERC-20 contract address string — because the
/// protocol's `token` parameter is stringly-typed across all chains (on Sui,
/// token identifiers are coin-type strings, not addresses).
extension EthereumRPCClient: BlockchainClientProtocol {
    public func getAllBalances(_ owner: EthereumAddress) async throws -> [String: BigUInt] {
        throw WalletKitError.unsupportedFeature
    }

    public func getBalances(_ owner: EthereumAddress, tokens: [String]) async throws -> [String: BigUInt] {
        let addresses = try tokens.map { try EthereumAddress(string: $0) }
        return try await erc20Balances(tokens: addresses, owner: owner)
    }

    public func getBalance(_ owner: EthereumAddress, token: String) async throws -> BigUInt {
        let token = try EthereumAddress(string: token)
        return try await erc20Balance(token: token, owner: owner)
    }

    public func getNativeBalance(_ owner: EthereumAddress) async throws -> BigUInt {
        try await nativeBalance(of: owner)
    }

    public func getTokenInfo(_ token: String?) async throws -> TokenInfo {
        guard let token else {
            return EVMBlockchain(chainId: chainId).nativeToken
        }
        let address = try EthereumAddress(string: token)
        return try await erc20TokenInfo(token: address)
    }

    public func getTokenPrice(_ token: String?) async throws -> Decimal {
        let symbol: String
        if let token {
            let address = try EthereumAddress(string: token)
            symbol = try await erc20TokenInfo(token: address).symbol
        } else {
            symbol = EVMBlockchain(chainId: chainId).nativeToken.symbol
        }

        let feed = try await chainlinkFeedAddress(base: symbol)

        async let round = latestRoundData(feed: feed)
        async let decimalsData = call(
            to: feed,
            data: EthereumABI.encodeCall(selector: EthereumABI.selector("decimals()"))
        )

        guard let decimalsWord = EthereumABI.words(try await decimalsData).first,
              let decimals = Int(exactly: EthereumABI.decodeUInt256(decimalsWord))
        else {
            throw BlockchainClientError.decodingFailed(reason: "empty or invalid decimals() response for price feed")
        }

        let answer = try await round.answer
        guard answer > 0 else {
            throw BlockchainClientError.decodingFailed(reason: "non-positive price feed answer")
        }

        return Decimal(sign: .plus, exponent: -decimals, significand: Decimal(answer))
    }

    public func isActiveAccount(_ owner: EthereumAddress) async throws -> Bool {
        let balance = try await nativeBalance(of: owner)
        guard balance == 0 else {
            return false
        }

        let nonce = try await nonce(of: owner)
        guard nonce == 0 else {
            return false
        }

        return true
    }

    public func isSupported(_ feature: BlockchainClientFeature) -> Bool {
        switch feature {
        case .multipleBalances: true
        case .allBalances: false
        case .feeEstimation: true
        }
    }

    // `estimateFee(for:)` is satisfied by the method defined in
    // `EthereumRPCClient.swift`, which has access to the private `rpc`
    // and `parseQuantity` helpers.

    /// Broadcasts a signed Ethereum transaction.
    ///
    /// For Ethereum the signed envelope is self-contained — `transaction`
    /// (the unsigned bytes) is unused. Pass the signed bytes as `signature`.
    public func broadcast(transaction: Data, signature: Data) async throws -> String {
        try await broadcast(signature)
    }
}
