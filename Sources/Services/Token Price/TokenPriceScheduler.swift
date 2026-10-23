import Foundation

/// Keeps account-relevant token prices fresh. Fetches one token at a time, oldest price first, so
/// rate-limited public sources see a steady trickle instead of bursts (ADR-047).
actor TokenPriceScheduler {
    static let batchSize = 10
    /// Retry delay for a token whose last fetch failed, so unpriceable tokens don't drain quotas.
    static let failureRetryInterval: TimeInterval = 10 * 60
    static let idleDelay = Duration.seconds(15)
    static let maxRateLimitBackoff = Duration.seconds(10 * 60)
    static let minRateLimitBackoff = Duration.seconds(30)
    static let refreshInterval: TimeInterval = 60
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

        for (index, request) in requests.enumerated() {
            guard !Task.isCancelled else {
                return .zero
            }

            if index > 0 {
                try? await Task.sleep(for: Self.tokenSpacing)
            }

            if await updatePrice(request) == .rateLimited {
                return nextRateLimitBackoff()
            }
        }

        // A full batch suggests more tokens are due.
        return requests.count < Self.batchSize ? Self.idleDelay : Self.tokenSpacing
    }
}

private extension TokenPriceScheduler {
    enum Outcome {
        case failed
        case rateLimited
        case updated
    }

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

    func updatePrice(_ request: TokenPriceRequest) async -> Outcome {
        let token = request.token

        do {
            let price = try await priceService.resolvedPrice(token, rpcURL: request.rpcURL)

            var updatedToken = token
            updatedToken.coinGeckoId = price.coinGeckoId ?? token.coinGeckoId
            updatedToken.usdPrice = price.usdPrice
            try await databaseService.updateTokenPrices([updatedToken])

            rateLimitBackoff = nil
            printVerbose("\(request.description): \(price.usdPrice) USD")
            return .updated
        } catch {
            // Stamp failures too, so a token that always fails can't hold up the rest of the queue.
            do {
                try await databaseService.markTokenPriceFetchFailed(token, at: .now)
            } catch {
                printError("Cannot mark \(request.description) price fetch failed: \(error)")
            }

            guard !error.isRateLimited else {
                return .rateLimited
            }

            printVerbose("\(request.description): no price: \(error)")
            return .failed
        }
    }
}

private extension TokenPriceRequest {
    var description: String {
        "\(token.symbol) [\(token.blockchain.map { "\($0)" } ?? "?")]"
    }
}
