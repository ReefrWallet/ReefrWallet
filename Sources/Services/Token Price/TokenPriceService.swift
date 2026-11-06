import SwiftData
import WalletKit

/// Fetches and persists token USD prices through an ordered source registry.
final class TokenPriceService: @unchecked Sendable {
    private let databaseService: DatabaseService?
    private let routes: PriceRoutes

    /// - Parameters:
    ///   - sources: Universal sources tried for every token, in order; no per-chain routing.
    ///   - routes: Per-chain and universal sources; takes precedence over `sources`.
    init(
        databaseService: DatabaseService? = nil,
        sources: [any PriceSource]? = nil,
        routes: PriceRoutes? = nil
    ) {
        if let routes {
            self.databaseService = databaseService
            self.routes = routes
        } else if let sources {
            self.databaseService = databaseService
            self.routes = PriceRoutes(chains: [:], universal: sources)
        } else {
            self.databaseService = databaseService ?? DI.injectOrFail(DatabaseService.self)
            self.routes = .live(clientProvider: DI.injectOrFail(BlockchainClientProvider.self))
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

    /// Tries the token's chain sources, then the universal ones, except that its last successful source goes first.
    func resolvedPrice(_ token: Token, rpcURL: URL) async throws -> ResolvedTokenPrice {
        try await resolvedPrices([TokenPriceRequest(rpcURL: rpcURL, token: token)])[0].get()
    }

    /// Like ``resolvedPrice(_:rpcURL:)`` for many tokens at once. Tokens that reach CoinGecko are
    /// priced together in a few requests; results align with `requests`.
    func resolvedPrices(_ requests: [TokenPriceRequest]) async -> [Result<ResolvedTokenPrice, any Swift.Error>] {
        var errors: [Int: any Swift.Error] = [:]
        var results = [Result<ResolvedTokenPrice, any Swift.Error>?](repeating: nil, count: requests.count)
        // Tokens waiting for CoinGecko, with the sources to try if it has no price.
        var deferred: [Int: [any PriceSource]] = [:]

        for (index, request) in requests.enumerated() {
            let ordered = orderedSources(for: request.token)

            if let coinGeckoIndex = ordered.firstIndex(where: { $0 is CoinGeckoPriceSource }) {
                deferred[index] = Array(ordered[(coinGeckoIndex + 1)...])
                results[index] = await price(request, from: ordered[..<coinGeckoIndex], error: &errors[index])
            } else {
                results[index] = await price(request, from: ordered[...], error: &errors[index])
            }
        }

        let coinGecko = routes.universal.lazy.compactMap { $0 as? CoinGeckoPriceSource }.first
        let pending = deferred.keys.sorted().filter { results[$0] == nil }

        if let coinGecko, !pending.isEmpty {
            let prices = await coinGecko.resolvedPrices(pending.map { requests[$0].token })

            for (index, price) in zip(pending, prices) {
                switch price {
                case let .success(.some(price)):
                    printVerbose("\(requests[index].token.symbol): CoinGeckoPriceSource -> \(price.usdPrice)")
                    results[index] = .success(ResolvedTokenPrice(
                        coinGeckoId: price.coinGeckoId,
                        sourceId: coinGecko.id,
                        usdPrice: price.usdPrice
                    ))
                case .success(.none):
                    printVerbose("\(requests[index].token.symbol): CoinGeckoPriceSource -> no price")
                case let .failure(error):
                    printVerbose("\(requests[index].token.symbol): CoinGeckoPriceSource failed: \(error)")
                    errors[index] = error
                }
            }
        }

        for index in pending where results[index] == nil {
            results[index] = await price(
                requests[index],
                from: (deferred[index] ?? [])[...],
                error: &errors[index]
            )
        }

        return results.enumerated().map { index, result in
            result ?? .failure(errors[index] ?? WalletKitError.unsupportedFeature)
        }
    }
}

private extension TokenPriceService {
    func orderedSources(for token: Token) -> [any PriceSource] {
        let sources = routes.sources(for: token.blockchain)
        return sources.filter { $0.id == token.priceSourceId } + sources.filter { $0.id != token.priceSourceId }
    }

    /// The first non-`nil` price among `candidates`, remembering the latest error.
    func price(
        _ request: TokenPriceRequest,
        from candidates: ArraySlice<any PriceSource>,
        error mostRecentError: inout (any Swift.Error)?
    ) async -> Result<ResolvedTokenPrice, any Swift.Error>? {
        let token = request.token

        for source in candidates {
            let name = String(describing: type(of: source))

            do {
                if let usdPrice = try await source.usdPrice(token, rpcURL: request.rpcURL) {
                    printVerbose("\(token.symbol): \(name) -> \(usdPrice)")
                    return .success(ResolvedTokenPrice(coinGeckoId: nil, sourceId: source.id, usdPrice: usdPrice))
                }

                printVerbose("\(token.symbol): \(name) -> unsupported/no price")
            } catch {
                printVerbose("\(token.symbol): \(name) failed: \(error)")
                mostRecentError = error
            }
        }

        return nil
    }
}

struct ResolvedTokenPrice: Sendable {
    let coinGeckoId: String?
    let sourceId: String
    let usdPrice: Decimal
}
