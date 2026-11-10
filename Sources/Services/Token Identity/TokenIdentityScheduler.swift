import Foundation
import WalletKit

/// Keeps token identities and images current, parallel to ``TokenPriceScheduler``. Identification
/// never pauses for rate limits, since the listing backs off on its own and local tables need no
/// network; image lookups back off separately.
actor TokenIdentityScheduler {
    static let idleDelay = Duration.seconds(15)

    private let priceScheduler: TokenPriceScheduler
    private let service: TokenIdentityService
    private var metadataBackoff = RateLimitBackoff()
    private var sleepTask: Task<Void, Never>?
    private var task: Task<Void, Never>?

    init(service: TokenIdentityService? = nil, priceScheduler: TokenPriceScheduler? = nil) {
        self.priceScheduler = priceScheduler ?? DI.injectOrFail(TokenPriceScheduler.self)
        self.service = service ?? DI.injectOrFail(TokenIdentityService.self)
    }

    /// Ends the current idle wait so due tokens are handled now.
    func refreshNow() {
        sleepTask?.cancel()
    }

    func start() {
        guard task == nil else {
            return
        }

        printDebug("Starting periodic token identification")

        task = Task(priority: .utility) { [weak self] in
            await RequestLane.$current.withValue(.balances) {
                await self?.service.resetRetriesIfConfigurationChanged()
                await self?.run()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        sleepTask?.cancel()
    }

    /// Runs both passes once.
    func runOnce(now: Date = .now) async {
        if await service.identifyDueTokens(now: now) > 0 {
            await priceScheduler.refreshNow()
        }

        guard !metadataBackoff.isPaused(at: now) else {
            return
        }

        if await service.enrichDueTokens(now: now) {
            metadataBackoff.recordRateLimit(at: now)
            printWarning("Token metadata rate-limited, pausing image lookups for \(metadataBackoff.delay ?? 0) s")
        } else {
            metadataBackoff.recordSuccess()
        }
    }

    private func run() async {
        while !Task.isCancelled {
            await runOnce()

            let sleeper = Task {
                _ = try? await Task.sleep(for: Self.idleDelay)
            }

            sleepTask = sleeper
            await sleeper.value
            sleepTask = nil
        }
    }
}
