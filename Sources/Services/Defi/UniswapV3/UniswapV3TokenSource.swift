//
//  UniswapV3TokenSource.swift
//  Reefr Wallet
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation
import WalletKit

/// Token metadata and USD prices for pool tokens.
protocol UniswapV3TokenSource: Sendable {
    /// Tokens by lowercased address; a token whose metadata can't be read is missing.
    func tokens(_ addresses: [EthereumAddress], account: Account, now: Date) async -> [String: UniswapV3Position.Token]
}

/// Stored tokens and prices when fresh, else on-chain metadata and a live quote.
struct LiveUniswapV3TokenSource: UniswapV3TokenSource {
    static let priceMaxAge: TimeInterval = 15 * 60

    func tokens(
        _ addresses: [EthereumAddress],
        account: Account,
        now: Date
    ) async -> [String: UniswapV3Position.Token] {
        let databaseService = DI.injectOrFail(DatabaseService.self)
        let priceService = DI.injectOrFail(TokenPriceService.self)
        let clientProvider = DI.injectOrFail(BlockchainClientProvider.self)
        let rpcURL = account.rpcURLOverride ?? account.blockchain.rpcURL
        var stored: [String: Token] = [:]
        var missing: [EthereumAddress] = []

        for address in addresses {
            let candidates = [address.string, address.string.lowercased()]
            var token: Token?

            for candidate in candidates where token == nil {
                token = try? await databaseService.fetchToken(tokenAddress: candidate, blockchain: account.blockchain)
            }

            if let token {
                stored[address.string.lowercased()] = token
            } else {
                missing.append(address)
            }
        }

        if !missing.isEmpty, let client = try? clientProvider.ethereumClient(for: account),
           let infos = try? await client.erc20TokenInfos(tokens: missing) {
            for (address, info) in zip(missing, infos) {
                if let info {
                    stored[address.string.lowercased()] = Token(
                        address: address.string,
                        blockchain: account.blockchain,
                        tokenInfo: info
                    )
                }
            }
        }

        var result: [String: UniswapV3Position.Token] = [:]

        for (key, token) in stored {
            var price = token.usdPrice
            var priceAt = token.priceUpdatedAt

            let isFresh = price != nil && !token.hasPriceFetchError
                && priceAt.map { now.timeIntervalSince($0) <= Self.priceMaxAge } == true

            if !isFresh {
                price = try? await priceService.usdPrice(token, rpcURL: rpcURL)
                priceAt = price == nil ? nil : now
            }

            result[key] = UniswapV3Position.Token(
                address: key,
                decimals: Int(token.decimalsCount),
                imageURL: token.imageURL,
                priceAt: priceAt,
                symbol: token.symbol,
                usdPrice: price
            )
        }

        return result
    }
}
