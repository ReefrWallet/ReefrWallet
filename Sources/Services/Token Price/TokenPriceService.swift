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
    /// priced together in a few requests; results align with `requests`. Each source's outcome is
    /// recorded per token, and a source that couldn't serve a token is skipped for a week (`now`
    /// dates both).
    func resolvedPrices(
        _ requests: [TokenPriceRequest],
        now: Date = .now
    ) async -> [Result<ResolvedTokenPrice, any Swift.Error>] {
        var pass = Pass(statuses: await statuses(for: requests))
        var results = [Result<ResolvedTokenPrice, any Swift.Error>?](repeating: nil, count: requests.count)
        // Tokens waiting for CoinGecko, with the sources to try if it has no price.
        var deferred: [Int: [any PriceSource]] = [:]

        for (index, request) in requests.enumerated() {
            let ordered = orderedSources(for: request.token, statuses: pass.statuses[index], now: now)

            if let coinGeckoIndex = ordered.firstIndex(where: { $0 is CoinGeckoPriceSource }) {
                deferred[index] = Array(ordered[(coinGeckoIndex + 1)...])
                results[index] = await price(request, index: index, from: ordered[..<coinGeckoIndex], pass: &pass)
            } else {
                results[index] = await price(request, index: index, from: ordered[...], pass: &pass)
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
                    pass.record(.success(externalId: price.coinGeckoId), source: coinGecko, request: requests[index])
                    results[index] = .success(ResolvedTokenPrice(
                        coinGeckoId: price.coinGeckoId,
                        sourceId: coinGecko.id,
                        usdPrice: price.usdPrice
                    ))
                case .success(.none):
                    printVerbose("\(requests[index].token.symbol): CoinGeckoPriceSource -> unsupported/no price")
                case let .failure(error):
                    printVerbose("\(requests[index].token.symbol): CoinGeckoPriceSource failed: \(error)")
                    pass.fail(error, source: coinGecko, index: index, request: requests[index])
                }
            }
        }

        for index in pending where results[index] == nil {
            results[index] = await price(
                requests[index],
                index: index,
                from: (deferred[index] ?? [])[...],
                pass: &pass
            )
        }

        await save(pass.results, at: now)

        return results.enumerated().map { index, result in
            result ?? .failure(pass.errors[index] ?? WalletKitError.unsupportedFeature)
        }
    }
}

private extension TokenPriceService {
    /// One resolution pass: the statuses it started from, and what it learned.
    struct Pass {
        /// The most telling error per request: rate limits, then other transient errors, then misses.
        var errors: [Int: any Swift.Error] = [:]
        var results: [TokenSourceResult] = []
        let statuses: [[TokenSourceStatus]]

        init(statuses: [[TokenSourceStatus]]) {
            self.statuses = statuses
        }

        mutating func fail(_ error: any Swift.Error, source: any PriceSource, index: Int, request: TokenPriceRequest) {
            record(TokenSourceOutcome(error: error), source: source, request: request)

            if Self.rank(error) >= errors[index].map(Self.rank) ?? 0 {
                errors[index] = error
            }
        }

        mutating func record(_ outcome: TokenSourceOutcome, source: any PriceSource, request: TokenPriceRequest) {
            results.append(TokenSourceResult(outcome: outcome, sourceId: source.id, token: request.token))
        }

        private static func rank(_ error: any Swift.Error) -> Int {
            if error.isRateLimited {
                3
            } else if error.isSourceUnavailable || error is NoQuote {
                1
            } else {
                2
            }
        }
    }

    func orderedSources(for token: Token, statuses: [TokenSourceStatus], now: Date) -> [any PriceSource] {
        let sources = routes.sources(for: token.blockchain).filter { source in
            !statuses.contains { $0.sourceId == source.id && $0.isSkipped(at: now) }
        }

        return sources.filter { $0.id == token.priceSourceId } + sources.filter { $0.id != token.priceSourceId }
    }

    /// The first non-`nil` price among `candidates`, remembering each source's outcome.
    func price(
        _ request: TokenPriceRequest,
        index: Int,
        from candidates: ArraySlice<any PriceSource>,
        pass: inout Pass
    ) async -> Result<ResolvedTokenPrice, any Swift.Error>? {
        let token = request.token

        for source in candidates {
            let name = String(describing: type(of: source))

            do {
                if let usdPrice = try await source.usdPrice(token, rpcURL: request.rpcURL) {
                    printVerbose("\(token.symbol): \(name) -> \(usdPrice)")
                    pass.record(.success(externalId: nil), source: source, request: request)
                    return .success(ResolvedTokenPrice(coinGeckoId: nil, sourceId: source.id, usdPrice: usdPrice))
                }

                printVerbose("\(token.symbol): \(name) -> unsupported/no price")
            } catch {
                printVerbose("\(token.symbol): \(name) failed: \(error)")
                pass.fail(error, source: source, index: index, request: request)
            }
        }

        return nil
    }

    func save(_ results: [TokenSourceResult], at date: Date) async {
        guard let databaseService, !results.isEmpty else {
            return
        }

        do {
            try await databaseService.recordTokenSourceResults(kind: .price, results, at: date)
        } catch {
            printError("Cannot record price source outcomes: \(error)")
        }
    }

    /// Statuses aligned with `requests`; empty when they can't be read, so nothing is skipped.
    func statuses(for requests: [TokenPriceRequest]) async -> [[TokenSourceStatus]] {
        let empty = [[TokenSourceStatus]](repeating: [], count: requests.count)

        guard let databaseService else {
            return empty
        }

        do {
            return try await databaseService.fetchTokenSourceStatuses(kind: .price, for: requests.map(\.token))
        } catch {
            printError("Cannot read price source statuses: \(error)")
            return empty
        }
    }
}

struct ResolvedTokenPrice: Sendable {
    let coinGeckoId: String?
    let sourceId: String
    let usdPrice: Decimal
}
