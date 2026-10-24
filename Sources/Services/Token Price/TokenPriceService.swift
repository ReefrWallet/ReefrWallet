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
        updatedToken.priceSourceId = price.sourceId
        updatedToken.usdPrice = price.usdPrice
        try await databaseService.updateTokenPrices([updatedToken])
        return price.usdPrice
    }

    /// Tries sources in registry order, except that `token`'s last successful source goes first.
    func resolvedPrice(_ token: Token, rpcURL: URL) async throws -> ResolvedTokenPrice {
        var mostRecentError: (any Swift.Error)?

        let orderedSources = sources.filter { $0.id == token.priceSourceId }
            + sources.filter { $0.id != token.priceSourceId }

        for source in orderedSources {
            let name = String(describing: type(of: source))

            do {
                if let coinGecko = source as? CoinGeckoPriceSource {
                    if let price = try await coinGecko.resolvedPrice(token, rpcURL: rpcURL) {
                        printVerbose("\(token.symbol): \(name) -> \(price.usdPrice)")
                        return ResolvedTokenPrice(
                            coinGeckoId: price.coinGeckoId,
                            sourceId: source.id,
                            usdPrice: price.usdPrice
                        )
                    }

                    printVerbose("\(token.symbol): \(name) -> no price")
                    continue
                }

                if let usdPrice = try await source.usdPrice(token, rpcURL: rpcURL) {
                    printVerbose("\(token.symbol): \(name) -> \(usdPrice)")
                    return ResolvedTokenPrice(coinGeckoId: nil, sourceId: source.id, usdPrice: usdPrice)
                }

                printVerbose("\(token.symbol): \(name) -> unsupported/no price")
            } catch {
                printVerbose("\(token.symbol): \(name) failed: \(error)")
                mostRecentError = error
            }
        }

        if let mostRecentError {
            throw mostRecentError
        }

        throw WalletKitError.unsupportedFeature
    }
}

struct ResolvedTokenPrice: Sendable {
    let coinGeckoId: String?
    let sourceId: String
    let usdPrice: Decimal
}
