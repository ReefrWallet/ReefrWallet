import Foundation
import WalletKit

/// Decides which tokens are real assets and fetches their optional details, through ordered
/// source lists. Each source's outcome is recorded per token, and a source that doesn't have a
/// token is skipped for it for a week.
final class TokenIdentityService: @unchecked Sendable {
    static let batchSize = 100
    /// Retry delay when every source declined the token (testnet, unmapped chain).
    static let declinedRetryInterval: TimeInterval = 24 * 60 * 60
    static let transientRetryInterval: TimeInterval = 10 * 60
    private static let configurationVersionKey = "TokenIdentityConfigurationVersion"

    private let databaseService: DatabaseService
    private let defaults: UserDefaults
    private let identitySources: [any TokenIdentitySource]
    private let metadataSources: [any TokenMetadataSource]

    init(
        databaseService: DatabaseService? = nil,
        identitySources: [any TokenIdentitySource]? = nil,
        metadataSources: [any TokenMetadataSource]? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.databaseService = databaseService ?? DI.injectOrFail(DatabaseService.self)
        self.defaults = defaults

        let provider = CoinGeckoListingProvider()
        let cacheURL = URL.cachesDirectory.appending(path: "xyz.reefr.wallet/coingecko-listing.json")
        let sharedListing = CachedTokenListing(provider: provider, cacheURL: cacheURL)

        self.identitySources = identitySources ?? [
            ChainlinkFeedIdentitySource.live,
            ListingIdentitySource(listing: sharedListing, provider: provider)
        ]

        self.metadataSources = metadataSources ?? [CoinGeckoMetadataSource(listing: sharedListing)]
    }

    /// Identifies a batch of due tokens. Returns how many were identified.
    @discardableResult
    func identifyDueTokens(now: Date = .now) async -> Int {
        let tokens: [Token]
        let statuses: [[TokenSourceStatus]]

        do {
            tokens = try await databaseService.fetchTokensDueForIdentity(now: now, limit: Self.batchSize)
            statuses = try await databaseService.fetchTokenSourceStatuses(kind: .identity, for: tokens)
        } catch {
            printError("Cannot fetch tokens due for identification: \(error)")
            return 0
        }

        guard !tokens.isEmpty else {
            return 0
        }

        printVerbose("Identity: \(tokens.count) tokens due")

        var pass = Pass()

        for source in identitySources {
            let indices = pass.eligibleIndices(tokens, statuses, sourceId: source.id, now: now) { pass, index in
                pass.identified[index] == nil
            }

            guard !indices.isEmpty else {
                continue
            }

            let results = await source.identities(of: indices.map { tokens[$0] })

            for (index, result) in zip(indices, results) {
                pass.apply(result, sourceId: source.id, token: tokens[index], index: index, now: now)
            }
        }

        await save(pass, tokens: tokens, now: now)
        return pass.identified.count
    }

    /// Fetches images for a batch of identified tokens. Returns whether a source rate-limited.
    @discardableResult
    func enrichDueTokens(now: Date = .now) async -> Bool {
        let tokens: [Token]
        let statuses: [[TokenSourceStatus]]

        do {
            tokens = try await databaseService.fetchTokensDueForMetadata(now: now, limit: Self.batchSize)
            statuses = try await databaseService.fetchTokenSourceStatuses(kind: .metadata, for: tokens)
        } catch {
            printError("Cannot fetch tokens due for metadata: \(error)")
            return false
        }

        guard !tokens.isEmpty else {
            return false
        }

        var pass = Pass()

        for source in metadataSources {
            let indices = pass.eligibleIndices(tokens, statuses, sourceId: source.id, now: now) { pass, index in
                pass.images[index] == nil && !pass.settled.contains(index)
            }

            guard !indices.isEmpty else {
                continue
            }

            let results = await source.metadata(for: indices.map { tokens[$0] })

            for (index, result) in zip(indices, results) {
                pass.apply(result, sourceId: source.id, token: tokens[index], index: index, now: now)
            }
        }

        await saveMetadata(pass, tokens: tokens, now: now)
        return pass.isRateLimited
    }

    /// Makes unidentified tokens due again when a source was added or its local data changed, so
    /// earlier negative answers don't outlive the data that gave them.
    func resetRetriesIfConfigurationChanged() async {
        let version = identitySources.map { "\($0.id):\($0.configurationVersion)" }.joined(separator: "|")

        guard defaults.string(forKey: Self.configurationVersionKey) != version else {
            return
        }

        do {
            try await databaseService.resetTokenIdentityRetries()
            defaults.set(version, forKey: Self.configurationVersionKey)
        } catch {
            printError("Cannot reset token identity retries: \(error)")
        }
    }
}

private extension TokenIdentityService {
    /// What one pass over the due tokens learned.
    struct Pass {
        var identified: [Int: (coinGeckoId: String?, token: Token)] = [:]
        var images: [Int: URL] = [:]
        var isRateLimited = false
        var recorded: [TokenSourceResult] = []
        /// The soonest any source could answer differently, per token.
        var retryAt: [Int: Date] = [:]
        /// Tokens left alone because their source rate-limited.
        var settled: Set<Int> = []

        /// Indices `isPending` allows whose source isn't skipped; skipped ones set the retry time.
        mutating func eligibleIndices(
            _ tokens: [Token],
            _ statuses: [[TokenSourceStatus]],
            sourceId: String,
            now: Date,
            where isPending: (Pass, Int) -> Bool
        ) -> [Int] {
            var indices: [Int] = []

            for index in tokens.indices where isPending(self, index) {
                if let skipped = statuses[index].first(where: { $0.sourceId == sourceId && $0.isSkipped(at: now) }) {
                    let since = skipped.unavailableAt ?? now
                    schedule(index, since.addingTimeInterval(TokenSourceStatus.unavailableRetryInterval))
                } else {
                    indices.append(index)
                }
            }

            return indices
        }

        mutating func schedule(_ index: Int, _ date: Date) {
            retryAt[index] = min(retryAt[index] ?? date, date)
        }

        mutating func scheduleAfterFailure(_ error: any Swift.Error, index: Int, now: Date) {
            if case .unavailable = TokenSourceOutcome(error: error) {
                schedule(index, now.addingTimeInterval(TokenSourceStatus.unavailableRetryInterval))
            } else {
                schedule(index, now.addingTimeInterval(TokenIdentityService.transientRetryInterval))
            }
        }

        mutating func apply(
            _ result: Result<TokenIdentity?, any Swift.Error>,
            sourceId: String,
            token: Token,
            index: Int,
            now: Date
        ) {
            switch result {
            case let .success(.some(identity)):
                printVerbose("\(token.symbol): identified by \(sourceId)")
                identified[index] = (sourceId == "coinGecko" ? identity.externalId : nil, token)
                let outcome = TokenSourceOutcome.success(externalId: identity.externalId)
                recorded.append(TokenSourceResult(outcome: outcome, sourceId: sourceId, token: token))
            case .success(.none):
                // A decline sets no date: the declined delay applies only if every source declines.
                break
            case let .failure(error):
                printVerbose("\(token.symbol): \(sourceId) did not identify it: \(error)")
                let outcome = TokenSourceOutcome(error: error)
                recorded.append(TokenSourceResult(outcome: outcome, sourceId: sourceId, token: token))
                scheduleAfterFailure(error, index: index, now: now)
            }
        }

        mutating func apply(
            _ result: Result<TokenMetadata?, any Swift.Error>,
            sourceId: String,
            token: Token,
            index: Int,
            now: Date
        ) {
            switch result {
            case let .success(.some(metadata)) where metadata.imageURL != nil:
                images[index] = metadata.imageURL
                recorded.append(TokenSourceResult(outcome: .success(externalId: nil), sourceId: sourceId, token: token))
            case .success:
                // Declined, e.g. no API key yet: look again soon.
                schedule(index, now.addingTimeInterval(TokenIdentityService.transientRetryInterval))
            case let .failure(error):
                printVerbose("\(token.symbol): \(sourceId) has no metadata: \(error)")
                let outcome = TokenSourceOutcome(error: error)
                recorded.append(TokenSourceResult(outcome: outcome, sourceId: sourceId, token: token))

                if error.isRateLimited {
                    isRateLimited = true
                    settled.insert(index)
                } else {
                    scheduleAfterFailure(error, index: index, now: now)
                }
            }
        }
    }

    func save(_ pass: Pass, tokens: [Token], now: Date) async {
        do {
            try await databaseService.recordTokenSourceResults(kind: .identity, pass.recorded, at: now)

            for found in pass.identified.values {
                try await databaseService.markTokenIdentified(found.token, coinGeckoId: found.coinGeckoId)
            }

            for index in tokens.indices where pass.identified[index] == nil {
                let fallback = now.addingTimeInterval(Self.declinedRetryInterval)
                try await databaseService.setTokenIdentityRetry(tokens[index], at: pass.retryAt[index] ?? fallback)
            }
        } catch {
            printError("Cannot save token identities: \(error)")
        }
    }

    func saveMetadata(_ pass: Pass, tokens: [Token], now: Date) async {
        do {
            try await databaseService.recordTokenSourceResults(kind: .metadata, pass.recorded, at: now)

            for index in tokens.indices where !pass.settled.contains(index) {
                let fallback = now.addingTimeInterval(Self.transientRetryInterval)
                try await databaseService.setTokenMetadata(
                    tokens[index],
                    imageURL: pass.images[index],
                    retryAt: pass.retryAt[index] ?? fallback
                )
            }
        } catch {
            printError("Cannot save token metadata: \(error)")
        }
    }
}
