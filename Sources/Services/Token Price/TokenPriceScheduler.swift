import Foundation

/// Keeps account-relevant token prices fresh. Prices all due tokens, oldest price first, in batched
/// requests so rate-limited public sources stay within quota (ADR-047).
actor TokenPriceScheduler {
    static let batchSize = 100
    /// Retry delay for a token whose last fetch failed, so unpriceable tokens don't drain quotas.
    static let failureRetryInterval: TimeInterval = 10 * 60
    static let idleDelay = Duration.seconds(15)
    static let maxRateLimitBackoff = Duration.seconds(10 * 60)
    static let minRateLimitBackoff = Duration.seconds(30)
    static let refreshInterval: TimeInterval = 5 * 60
    static let tokenSpacing = Duration.seconds(1)

    private let databaseService: DatabaseService
    private let priceService: TokenPriceService
    /// Set while sources report rate limiting; doubles per consecutive hit.
    private var rateLimitBackoff: Duration?
    private var sleepTask: Task<Void, Never>?
    private var task: Task<Void, Never>?

    init(databaseService: DatabaseService? = nil, priceService: TokenPriceService? = nil) {
        self.databaseService = databaseService ?? DI.injectOrFail(DatabaseService.self)
        self.priceService = priceService ?? DI.injectOrFail(TokenPriceService.self)
    }

    /// Ends the current idle wait so due tokens are fetched now. Never shortens a rate-limit backoff.
    func refreshNow() {
        guard rateLimitBackoff == nil else {
            return
        }

        sleepTask?.cancel()
    }

    func start() {
        guard task == nil else {
            return
        }

        printDebug("Starting periodic token price updates")

        task = Task(priority: .utility) { [weak self] in
            await self?.run()
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        sleepTask?.cancel()
    }

    /// Prices one batch of due tokens and returns how long to wait before the next batch.
    func updateDueTokens(now: Date = .now) async -> Duration {
        let requests: [TokenPriceRequest]

        do {
            requests = try await databaseService.fetchTokensDueForPriceUpdate(
                now: now,
                refreshInterval: Self.refreshInterval,
                failureRetryInterval: Self.failureRetryInterval,
                limit: Self.batchSize
            )
        } catch {
            printError("Cannot fetch tokens due for price update: \(error)")
            return Self.idleDelay
        }

        guard !requests.isEmpty else {
            return Self.idleDelay
        }

        printVerbose("Price update: \(requests.count) tokens due")

        let results = await priceService.resolvedPrices(requests, now: now)
        var isRateLimited = false
        var updatedTokens: [Token] = []

        for (request, result) in zip(requests, results) {
            switch result {
            case let .success(price):
                var token = request.token
                token.coinGeckoId = price.coinGeckoId ?? token.coinGeckoId
                token.priceSourceId = price.sourceId
                token.usdPrice = price.usdPrice
                updatedTokens.append(token)
                printVerbose("\(request.description): \(price.usdPrice) USD from \(price.sourceId)")
            case let .failure(error):
                guard !error.isRateLimited else {
                    isRateLimited = true
                    continue
                }

                printVerbose("\(request.description): no price: \(error)")
                await markFailed(request)
            }
        }

        do {
            try await databaseService.updateTokenPrices(updatedTokens)
        } catch {
            printError("Cannot save token prices: \(error)")
        }

        guard !isRateLimited else {
            return nextRateLimitBackoff()
        }

        rateLimitBackoff = nil

        // A full batch suggests more tokens are due.
        return requests.count < Self.batchSize ? Self.idleDelay : Self.tokenSpacing
    }
}

private extension TokenPriceScheduler {
    func nextRateLimitBackoff() -> Duration {
        let backoff = rateLimitBackoff.map { min($0 * 2, Self.maxRateLimitBackoff) } ?? Self.minRateLimitBackoff
        rateLimitBackoff = backoff
        printWarning("Price sources rate-limited, pausing price updates for \(backoff)")
        return backoff
    }

    func run() async {
        while !Task.isCancelled {
            let delay = await updateDueTokens()

            guard delay > .zero else {
                continue
            }

            let sleeper = Task {
                _ = try? await Task.sleep(for: delay)
            }

            sleepTask = sleeper
            await sleeper.value
            sleepTask = nil
        }
    }

    /// Stamps failures too, so a token that always fails can't hold up the rest of the queue.
    func markFailed(_ request: TokenPriceRequest) async {
        do {
            try await databaseService.markTokenPriceFetchFailed(request.token, at: .now)
        } catch {
            printError("Cannot mark \(request.description) price fetch failed: \(error)")
        }
    }
}

private extension TokenPriceRequest {
    var description: String {
        "\(token.symbol) [\(token.blockchain.map { "\($0)" } ?? "?")]"
    }
}
