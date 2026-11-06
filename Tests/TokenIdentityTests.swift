import Alamofire
import Foundation
import Testing
import WalletKit
@testable import ReefrWallet

@Suite(.serialized, .timeLimit(.minutes(1)))
struct TokenIdentityTests {
    // MARK: Feed tables

    @Test func feedTableTokensAreIdentifiedWithoutNetworkOrKey() async throws {
        let source = ChainlinkFeedIdentitySource.live
        let usdc = TokenSourceFixture.token("1").with(address: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48")
        let squatter = TokenSourceFixture.token("2", symbol: "USDC")

        let results = await source.identities(of: [usdc, squatter])

        #expect(try results[0].get() != nil)
        #expect(try results[1].get() == nil)
    }

    @Test func feedTableVersionChangesWhenATableChanges() {
        let feed = ChainlinkPriceSource.Feed(address: "0xfeed", heartbeat: 1)
        let one = feedSource(["0xa": feed])
        let two = feedSource(["0xa": feed, "0xb": feed])

        #expect(one.configurationVersion != two.configurationVersion)
        #expect(one.configurationVersion == one.configurationVersion)
    }

    // MARK: Listings

    @Test func aListingIdentifiesByContractAddressNeverBySymbol() async throws {
        let provider = StubListingProvider(entries: [listed("a", "usd-coin")])
        let source = identitySource(provider)
        let real = TokenSourceFixture.token("A")
        let squatter = TokenSourceFixture.token("2", symbol: "USDC")

        let results = await source.identities(of: [real, squatter])

        #expect(try results[0].get()?.externalId == "usd-coin")
        #expect(throws: TokenNotListed.self) { try results[1].get() }
    }

    @Test func solanaAddressesAreComparedExactly() {
        let listing = TokenListing(
            entries: [TokenListingEntry(address: "AbCd", externalId: "x", platform: "solana")],
            fetchedAt: .now
        )

        #expect(listing.externalId(platform: "solana", address: "AbCd") == "x")
        #expect(listing.externalId(platform: "solana", address: "abcd") == nil)
    }

    @Test func aListingIsFetchedOncePerDayAndOnlyWhenNeeded() async throws {
        let provider = StubListingProvider(entries: [listed("A", "a")])
        let clock = Box(Date.now)
        let source = identitySource(provider, clock: clock)

        _ = await source.identities(of: [TokenSourceFixture.token("1").with(address: nil)])
        #expect(provider.fetches.isEmpty)

        _ = await source.identities(of: [TokenSourceFixture.token("A")])
        _ = await source.identities(of: [TokenSourceFixture.token("A")])
        #expect(provider.fetches.count == 1)

        clock.value = clock.value.addingTimeInterval(CachedTokenListing.maxAge + 1)
        _ = await source.identities(of: [TokenSourceFixture.token("A")])
        #expect(provider.fetches.count == 2)
    }

    @Test func aFailedRefreshKeepsPositivesAndNeverReportsAMissAsFinal() async throws {
        let provider = StubListingProvider(entries: [listed("A", "a")])
        let clock = Box(Date.now)
        let source = identitySource(provider, clock: clock)

        _ = await source.identities(of: [TokenSourceFixture.token("A")])
        provider.failure.value = BlockchainClientError.transportError(reason: "offline")
        clock.value = clock.value.addingTimeInterval(CachedTokenListing.maxAge + 1)

        let results = await source.identities(of: [TokenSourceFixture.token("A"), TokenSourceFixture.token("B")])

        #expect(try results[0].get()?.externalId == "a")
        guard case let .failure(error) = results[1] else {
            Issue.record("a stale miss must not be final")
            return
        }
        #expect(!(error is TokenNotListed))
        #expect(!TokenSourceOutcome(error: error).isUnavailable)
    }

    @Test func anUndersizedListingIsRejected() async {
        let provider = StubListingProvider(entries: [listed("A", "a")], minimumEntryCount: 5)
        let source = identitySource(provider)

        let results = await source.identities(of: [TokenSourceFixture.token("A")])

        guard case let .failure(error) = results[0] else {
            Issue.record("expected a failure")
            return
        }
        #expect(!(error is TokenNotListed))
    }

    @Test func aRateLimitedListingBacksOffOnItsOwn() async {
        let provider = StubListingProvider(entries: [listed("A", "a")])
        provider.failure.value = AFError.responseValidationFailed(reason: .unacceptableStatusCode(code: 429))
        let clock = Box(Date.now)
        let source = identitySource(provider, clock: clock)

        _ = await source.identities(of: [TokenSourceFixture.token("A")])
        _ = await source.identities(of: [TokenSourceFixture.token("A")])
        #expect(provider.fetches.count == 1)

        clock.value = clock.value.addingTimeInterval(RateLimitBackoff.minDelay + 1)
        _ = await source.identities(of: [TokenSourceFixture.token("A")])
        #expect(provider.fetches.count == 2)
    }

    @Test func aListingSurvivesRelaunchThroughItsCacheFile() async throws {
        let url = URL.temporaryDirectory.appending(path: "listing-\(UUID().uuidString)/listing.json")
        let provider = StubListingProvider(entries: [listed("A", "a")])
        _ = await CachedTokenListing(provider: provider, cacheURL: url).access()

        let offline = StubListingProvider(entries: [])
        offline.failure.value = BlockchainClientError.transportError(reason: "offline")
        let access = await CachedTokenListing(provider: offline, cacheURL: url).access()

        #expect(access.isFresh)
        #expect(access.listing?.externalId(platform: "ethereum", address: TokenSourceFixture.address("A")) == "a")
        #expect(offline.fetches.isEmpty)
    }

    // MARK: Service

    @Test func anIdentifiedTokenIsWhitelistedAndDueForPricingAtOnce() async throws {
        let fixture = try await TokenSourceFixture()
        let token = try await fixture.insertToken("1")
        try await fixture.databaseService.markTokenPriceFetchFailed(token, at: .now)
        let nudged = Box(false)
        let service = makeService(fixture, [
            StubIdentitySource(id: "yes") { _ in .success(TokenIdentity(externalId: "coin")) }
        ])

        let identified = await service.identifyDueTokens()

        nudged.value = identified > 0
        #expect(nudged.value)
        let stored = try await fixture.storedToken(token)
        #expect(stored.isWhitelisted)
        #expect(stored.identityRetryAt == nil)
        #expect(!stored.hasPriceFetchError)

        let due = try await fixture.databaseService.fetchTokensDueForPriceUpdate(
            now: .now,
            refreshInterval: 300,
            failureRetryInterval: 600,
            limit: 100
        )
        #expect(due.contains { $0.token.address == token.address })
    }

    @Test func aMissIsRememberedForAWeekAndOthersRetryAfterTenMinutes() async throws {
        let fixture = try await TokenSourceFixture()
        let missing = try await fixture.insertToken("1")
        let offline = try await fixture.insertToken("2")
        let counter = CallCounter()

        let service = makeService(fixture, [StubIdentitySource(id: "list") { token in
            counter.increment()
            return token.address == missing.address
                ? .failure(TokenNotListed())
                : .failure(BlockchainClientError.transportError(reason: "offline"))
        }])

        let start = Date.now
        await service.identifyDueTokens(now: start)

        let missingRetry = try #require(try await fixture.storedToken(missing).identityRetryAt)
        let offlineRetry = try #require(try await fixture.storedToken(offline).identityRetryAt)
        #expect(abs(missingRetry.timeIntervalSince(start) - 7 * 86_400) < 1)
        #expect(abs(offlineRetry.timeIntervalSince(start) - 600) < 1)

        // Only the offline token is due again; the missing one waits out its week.
        await service.identifyDueTokens(now: start.addingTimeInterval(601))
        #expect(counter.count == 3)
    }

    @Test func aTokenIsIdentifiedByALaterSourceWhenTheFirstDoesNotKnowIt() async throws {
        let fixture = try await TokenSourceFixture()
        let token = try await fixture.insertToken("1")
        let service = makeService(fixture, [
            StubIdentitySource(id: "first") { _ in .failure(TokenNotListed()) },
            StubIdentitySource(id: "second") { _ in .success(TokenIdentity(externalId: "second-id")) }
        ])

        await service.identifyDueTokens()

        #expect(try await fixture.storedToken(token).isWhitelisted)
        let statuses = try await fixture.statuses(.identity, of: token)
        #expect(statuses.first { $0.sourceId == "first" }?.unavailableAt != nil)
        #expect(statuses.first { $0.sourceId == "second" }?.externalId == "second-id")
    }

    @Test func changingTheSourceConfigurationRechecksRejectedTokens() async throws {
        let fixture = try await TokenSourceFixture()
        let token = try await fixture.insertToken("1")
        let defaults = UserDefaults(suiteName: "identity-\(UUID().uuidString)")!
        let rejecting = StubIdentitySource(id: "table", version: "1") { _ in .failure(TokenNotListed()) }

        let before = makeService(fixture, [rejecting], defaults: defaults)
        await before.resetRetriesIfConfigurationChanged()
        await before.identifyDueTokens()
        #expect(try await fixture.storedToken(token).identityRetryAt != nil)

        await before.resetRetriesIfConfigurationChanged()
        #expect(try await fixture.storedToken(token).identityRetryAt != nil)

        let accepting = StubIdentitySource(id: "table", version: "2") { _ in .success(TokenIdentity(externalId: nil)) }
        let after = makeService(fixture, [accepting], defaults: defaults)
        await after.resetRetriesIfConfigurationChanged()
        await after.identifyDueTokens()

        #expect(try await fixture.storedToken(token).isWhitelisted)
    }

    @Test func aDeclineDoesNotShortenAWeeklyRetry() async throws {
        let fixture = try await TokenSourceFixture()
        let token = try await fixture.insertToken("1")
        let service = makeService(fixture, [
            StubIdentitySource(id: "table") { _ in .success(nil) },
            StubIdentitySource(id: "list") { _ in .failure(TokenNotListed()) }
        ])
        let start = Date.now

        await service.identifyDueTokens(now: start)

        let retry = try #require(try await fixture.storedToken(token).identityRetryAt)
        #expect(abs(retry.timeIntervalSince(start) - 7 * 86_400) < 1)
    }

    @Test func aTokenWithoutACoinGeckoIdGetsItFromTheListingForItsImage() async throws {
        let provider = StubListingProvider(entries: [listed("1", "real-coin")])
        let source = CoinGeckoMetadataSource(
            apiKey: { nil },
            listing: CachedTokenListing(provider: provider)
        )

        // Without a key nothing is requested, but the listing is only consulted once a key exists.
        let results = await source.metadata(for: [TokenSourceFixture.token("1")])

        #expect(try results[0].get() == nil)
    }

    // MARK: Metadata

    @Test func anImageFailureRetriesLaterWithoutTouchingIdentity() async throws {
        let fixture = try await TokenSourceFixture()
        let token = try await fixture.insertToken("1", isWhitelisted: true)
        let isOffline = Box(true)

        let service = makeService(fixture, [], metadata: [StubMetadataSource(id: "img") { _ in
            guard !isOffline.value else {
                return .failure(BlockchainClientError.transportError(reason: "offline"))
            }

            return .success(TokenMetadata(imageURL: URL(string: "https://img.example/a.png")))
        }])

        let start = Date.now
        await service.enrichDueTokens(now: start)
        #expect(try await fixture.databaseService.fetchTokensDueForMetadata(now: start, limit: 10).isEmpty)

        isOffline.value = false
        let retry = start.addingTimeInterval(601)
        #expect(try await fixture.databaseService.fetchTokensDueForMetadata(now: retry, limit: 10).count == 1)
        await service.enrichDueTokens(now: retry)

        let stored = try await fixture.storedToken(token)
        #expect(stored.isWhitelisted)
        #expect(stored.imageURL?.absoluteString == "https://img.example/a.png")
    }

    @Test func aDeclinedImageLookupRetriesSoWhenAKeyArrives() async throws {
        let fixture = try await TokenSourceFixture()
        try await fixture.insertToken("1", isWhitelisted: true)
        let counter = CallCounter()

        let service = makeService(fixture, [], metadata: [StubMetadataSource(id: "img") { _ in
            counter.increment()
            return .success(nil)
        }])

        let start = Date.now
        await service.enrichDueTokens(now: start)
        await service.enrichDueTokens(now: start.addingTimeInterval(601))

        #expect(counter.count == 2)
    }

    @Test func aMissingImageIsNotAskedForAgainForAWeek() async throws {
        let fixture = try await TokenSourceFixture()
        try await fixture.insertToken("1", isWhitelisted: true)
        let counter = CallCounter()

        let service = makeService(fixture, [], metadata: [StubMetadataSource(id: "img") { _ in
            counter.increment()
            return .failure(TokenNotListed())
        }])

        let start = Date.now
        await service.enrichDueTokens(now: start)
        await service.enrichDueTokens(now: start.addingTimeInterval(6 * 86_400))
        #expect(counter.count == 1)
        await service.enrichDueTokens(now: start.addingTimeInterval(8 * 86_400))
        #expect(counter.count == 2)
    }

    @Test func aRateLimitedImageLookupPausesOnlyImageLookups() async throws {
        let fixture = try await TokenSourceFixture()
        try await fixture.insertToken("1", isWhitelisted: true)
        let spam = try await fixture.insertToken("2")
        let images = CallCounter()

        let service = makeService(
            fixture,
            [StubIdentitySource(id: "yes") { _ in .success(TokenIdentity(externalId: nil)) }],
            metadata: [StubMetadataSource(id: "img") { _ in
                images.increment()
                return .failure(AFError.responseValidationFailed(reason: .unacceptableStatusCode(code: 429)))
            }]
        )

        let scheduler = TokenIdentityScheduler(
            service: service,
            priceScheduler: TokenPriceScheduler(
                databaseService: fixture.databaseService,
                priceService: TokenPriceService(databaseService: fixture.databaseService, sources: [])
            )
        )

        let start = Date.now
        await scheduler.runOnce(now: start)
        await scheduler.runOnce(now: start.addingTimeInterval(1))

        #expect(try await fixture.storedToken(spam).isWhitelisted)
        #expect(images.count == 2)

        await scheduler.runOnce(now: start.addingTimeInterval(2))
        #expect(images.count == 2)
    }
}

private extension Token {
    func with(address: String?) -> Token {
        Token(
            address: address,
            blockchain: blockchain ?? TokenSourceFixture.blockchain,
            coinGeckoId: nil,
            decimalsCount: decimalsCount,
            imageURL: nil,
            isHidden: false,
            isIncludedInBalance: true,
            isNativeToken: false,
            name: name,
            symbol: symbol,
            usdPrice: nil
        )
    }
}

private extension TokenSourceOutcome {
    var isUnavailable: Bool {
        if case .unavailable = self {
            true
        } else {
            false
        }
    }
}

private func listed(_ suffix: String, _ id: String) -> TokenListingEntry {
    TokenListingEntry(address: TokenSourceFixture.address(suffix), externalId: id, platform: "ethereum")
}

private func feedSource(_ tokens: [String: ChainlinkPriceSource.Feed]) -> ChainlinkFeedIdentitySource {
    let feed = ChainlinkPriceSource.Feed(address: "0xfeed", heartbeat: 1)
    return ChainlinkFeedIdentitySource(feeds: [TokenSourceFixture.blockchain: .table(native: feed, tokens: tokens)])
}

private func identitySource(
    _ provider: StubListingProvider,
    clock: Box<Date> = Box(.now)
) -> ListingIdentitySource {
    ListingIdentitySource(
        listing: CachedTokenListing(provider: provider, now: { clock.value }),
        provider: provider
    )
}

private func makeService(
    _ fixture: TokenSourceFixture,
    _ identity: [any TokenIdentitySource],
    metadata: [any TokenMetadataSource] = [],
    defaults: UserDefaults = UserDefaults(suiteName: "identity-\(UUID().uuidString)")!
) -> TokenIdentityService {
    TokenIdentityService(
        databaseService: fixture.databaseService,
        identitySources: identity,
        metadataSources: metadata,
        defaults: defaults
    )
}

private struct StubIdentitySource: TokenIdentitySource {
    let answer: @Sendable (Token) -> Result<TokenIdentity?, any Swift.Error>
    let configurationVersion: String
    let id: String

    init(
        id: String,
        version: String = "1",
        answer: @escaping @Sendable (Token) -> Result<TokenIdentity?, any Swift.Error>
    ) {
        self.answer = answer
        configurationVersion = version
        self.id = id
    }

    func identities(of tokens: [Token]) async -> [Result<TokenIdentity?, any Swift.Error>] {
        tokens.map(answer)
    }
}

private struct StubMetadataSource: TokenMetadataSource {
    let answer: @Sendable (Token) -> Result<TokenMetadata?, any Swift.Error>
    let id: String

    init(id: String, answer: @escaping @Sendable (Token) -> Result<TokenMetadata?, any Swift.Error>) {
        self.answer = answer
        self.id = id
    }

    func metadata(for tokens: [Token]) async -> [Result<TokenMetadata?, any Swift.Error>] {
        tokens.map(answer)
    }
}

private final class StubListingProvider: TokenListingProvider, @unchecked Sendable {
    let entries: [TokenListingEntry]
    let failure = Box<(any Swift.Error)?>(nil)
    let fetches = CallCounter()
    let minimumEntryCount: Int

    init(entries: [TokenListingEntry], minimumEntryCount: Int = 1) {
        self.entries = entries
        self.minimumEntryCount = minimumEntryCount
    }

    var id: String {
        "stub"
    }

    func fetchEntries() async throws -> [TokenListingEntry] {
        fetches.increment()

        if let error = failure.value {
            throw error
        }

        return entries
    }

    func platform(for blockchain: Blockchain) -> String? {
        CoinGeckoPriceSource.assetPlatform(for: blockchain)
    }
}
