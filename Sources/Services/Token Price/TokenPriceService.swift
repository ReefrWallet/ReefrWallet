import SwiftData
import WalletKit

/// Fetches and persists token USD prices through an ordered source registry.
final class TokenPriceService: @unchecked Sendable {
    private let databaseService: DatabaseService?
    private let sources: [any PriceSource]

    init(
        databaseService: DatabaseService? = nil,
        sources: [any PriceSource]? = nil
    ) {
        if let sources {
            self.databaseService = databaseService
            self.sources = sources
        } else {
            self.databaseService = databaseService ?? DI.injectOrFail(DatabaseService.self)

            let clientProvider = DI.injectOrFail(BlockchainClientProvider.self)
            self.sources = [
                ChainlinkPriceSource(clientProvider: clientProvider),
                UniswapV3PriceSource(clientProvider: clientProvider),
                CetusPriceSource(clientProvider: clientProvider),
                CoinGeckoPriceSource()
            ]
        }
    }

    func usdPrice(_ token: Token, rpcURL: URL) async throws -> Decimal {
        let price = try await resolvedPrice(token, rpcURL: rpcURL)

        guard let coinGeckoId = price.coinGeckoId,
              token.coinGeckoId != coinGeckoId,
              let databaseService else {
            return price.usdPrice
        }

        var updatedToken = token
        updatedToken.coinGeckoId = coinGeckoId
        updatedToken.usdPrice = price.usdPrice
        try await databaseService.updateTokenPrices([updatedToken])
        return price.usdPrice
    }

    func updateTokenPrices(_ account: Account) async throws {
        guard let databaseService else {
            throw WalletKitError.unsupportedFeature
        }

        let tokens = try await databaseService.fetchTokens(account: account)

        let updatedTokens = await withTaskGroup(of: Token?.self) { group in
            for token in tokens {
                group.addTask { [self] in
                    do {
                        let price = try await resolvedPrice(
                            token,
                            rpcURL: account.rpcURLOverride ?? account.blockchain.rpcURL
                        )

                        var updatedToken = token
                        updatedToken.coinGeckoId = price.coinGeckoId ?? token.coinGeckoId
                        updatedToken.usdPrice = price.usdPrice
                        return updatedToken
                    } catch {
                        printError("\(account.name): \(error)")
                        return nil
                    }
                }
            }

            var results: [Token] = []

            for await updatedToken in group {
                if let updatedToken {
                    results.append(updatedToken)
                }
            }

            return results
        }

        try await databaseService.updateTokenPrices(updatedTokens)
    }

    private func resolvedPrice(_ token: Token, rpcURL: URL) async throws -> CoinGeckoPrice {
        var mostRecentError: (any Swift.Error)?

        for source in sources {
            do {
                if let coinGecko = source as? CoinGeckoPriceSource,
                   let price = try await coinGecko.resolvedPrice(token, rpcURL: rpcURL) {
                    return price
                }

                if let usdPrice = try await source.usdPrice(token, rpcURL: rpcURL) {
                    return CoinGeckoPrice(coinGeckoId: nil, usdPrice: usdPrice)
                }
            } catch {
                mostRecentError = error
            }
        }

        if let mostRecentError {
            throw mostRecentError
        }

        throw WalletKitError.unsupportedFeature
    }
}
