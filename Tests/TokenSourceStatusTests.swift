import Alamofire
import Foundation
import Testing
import WalletKit
@testable import ReefrWallet

@Suite(.serialized, .timeLimit(.minutes(1)))
struct TokenSourceStatusTests {
    @Test func sortsFailuresByWhetherTheyShowTheTokenIsMissing() async {
        let unavailable: [any Swift.Error] = [
            TokenNotListed(),
            BlockchainClientError.rpcError(code: 3, message: "execution reverted"),
            BlockchainClientError.decodingFailed(reason: "empty getPool(address,address,uint24) response")
        ]

        let transient: [any Swift.Error] = [
            BlockchainClientError.transportError(reason: "offline"),
            BlockchainClientError.invalidResponse(reason: "unexpected HTTP status 500"),
            BlockchainClientError.rpcError(code: -32_005, message: "limit exceeded"),
            AFError.responseValidationFailed(reason: .unacceptableStatusCode(code: 429)),
            ChainlinkPriceSource.StaleAnswer(age: 1, heartbeat: 1)
        ]

        for error in unavailable {
            #expect(error.isSourceUnavailable, "\(error)")
        }

        for error in transient {
            #expect(!error.isSourceUnavailable, "\(error)")
        }
    }

    @Test func aSourceThatDoesNotHaveTheTokenIsSkippedForAWeek() async throws {
        let fixture = try await TokenSourceFixture()
        let token = try await fixture.insertToken("1", isWhitelisted: true)
        let counter = CallCounter()

        let service = TokenPriceService(databaseService: fixture.databaseService, sources: [
            ScriptedSource(id: "missing") { _ in
                counter.increment()
                throw TokenNotListed()
            }
        ])

        let start = Date.now
        _ = await service.resolvedPrices([request(token)], now: start)
        _ = await service.resolvedPrices([request(token)], now: start.addingTimeInterval(6 * 86_400))
        #expect(counter.count == 1)

        let status = try #require(try await fixture.statuses(.price, of: token).first)
        #expect(status.unavailableAt != nil)
        #expect(status.lastError != nil)

        _ = await service.resolvedPrices([request(token)], now: start.addingTimeInterval(8 * 86_400))
        #expect(counter.count == 2)
    }

    @Test func aSuccessfulRetryClearsTheSkip() async throws {
        let fixture = try await TokenSourceFixture()
        let token = try await fixture.insertToken("1", isWhitelisted: true)
        let isListed = Box(false)

        let service = TokenPriceService(databaseService: fixture.databaseService, sources: [
            ScriptedSource(id: "flaky") { _ in
                guard isListed.value else {
                    throw TokenNotListed()
                }

                return 5
            }
        ])

        let start = Date.now
        _ = await service.resolvedPrices([request(token)], now: start)
        isListed.value = true
        let results = await service.resolvedPrices([request(token)], now: start.addingTimeInterval(8 * 86_400))

        #expect(try results[0].get().usdPrice == 5)
        let status = try #require(try await fixture.statuses(.price, of: token).first)
        #expect(status.unavailableAt == nil)
        #expect(status.lastSuccessAt != nil)
    }

    @Test func transientFailuresAndNoQuotesAreRecordedButNeverSkipped() async throws {
        let fixture = try await TokenSourceFixture()
        let transient = try await fixture.insertToken("1", isWhitelisted: true)
        let noQuote = try await fixture.insertToken("2", isWhitelisted: true)
        let counter = CallCounter()

        let service = TokenPriceService(databaseService: fixture.databaseService, sources: [
            ScriptedSource(id: "unreliable") { token in
                counter.increment()

                if token.address == transient.address {
                    throw BlockchainClientError.transportError(reason: "offline")
                }

                throw NoQuote()
            }
        ])

        let start = Date.now
        _ = await service.resolvedPrices([request(transient), request(noQuote)], now: start)
        _ = await service.resolvedPrices([request(transient), request(noQuote)], now: start.addingTimeInterval(60))

        #expect(counter.count == 4)

        for token in [transient, noQuote] {
            let status = try #require(try await fixture.statuses(.price, of: token).first)
            #expect(status.lastErrorAt != nil)
            #expect(status.unavailableAt == nil)
        }
    }

    @Test func declinedTokensLeaveNoStatusRows() async throws {
        let fixture = try await TokenSourceFixture()
        let token = try await fixture.insertToken("1", isWhitelisted: true)
        let service = TokenPriceService(
            databaseService: fixture.databaseService,
            sources: [ScriptedSource(id: "none") { _ in nil }]
        )

        _ = await service.resolvedPrices([request(token)])

        #expect(try await fixture.statuses(.price, of: token).isEmpty)
    }

    @Test func aRateLimitIsNotHiddenByALaterMiss() async throws {
        let fixture = try await TokenSourceFixture()
        let token = try await fixture.insertToken("1", isWhitelisted: true)

        let service = TokenPriceService(databaseService: fixture.databaseService, sources: [
            ScriptedSource(id: "limited") { _ in
                throw AFError.responseValidationFailed(reason: .unacceptableStatusCode(code: 429))
            },
            ScriptedSource(id: "missing") { _ in throw TokenNotListed() }
        ])

        let results = await service.resolvedPrices([request(token)])

        guard case let .failure(error) = results[0] else {
            Issue.record("expected a failure")
            return
        }

        #expect(error.isRateLimited)
    }

    @Test func aTokenWhoseSourcesAreAllSkippedMakesNoCalls() async throws {
        let fixture = try await TokenSourceFixture()
        let token = try await fixture.insertToken("1", isWhitelisted: true)
        let counter = CallCounter()

        let service = TokenPriceService(databaseService: fixture.databaseService, sources: [
            ScriptedSource(id: "missing") { _ in
                counter.increment()
                throw TokenNotListed()
            }
        ])

        let start = Date.now
        _ = await service.resolvedPrices([request(token)], now: start)
        let results = await service.resolvedPrices([request(token)], now: start.addingTimeInterval(3_600))

        #expect(counter.count == 1)
        #expect(throws: (any Swift.Error).self) { try results[0].get() }
    }

    @Test func deletingAllTokensRemovesTheirStatuses() async throws {
        let fixture = try await TokenSourceFixture()
        let token = try await fixture.insertToken("1", isWhitelisted: true)
        let service = TokenPriceService(
            databaseService: fixture.databaseService,
            sources: [ScriptedSource(id: "x") { _ in 1 }]
        )

        _ = await service.resolvedPrices([request(token)])
        #expect(try await fixture.statuses(.price, of: token).count == 1)

        try await fixture.databaseService.deleteAllTokens()

        #expect(try await fixture.statuses(.price, of: token).isEmpty)
    }

    @Test func aBalanceSaveNeverOverwritesANewerPriceWithAnOlderSnapshot() async throws {
        let fixture = try await TokenSourceFixture()
        let stale = try await fixture.insertToken("1", isWhitelisted: true, usdPrice: 1)

        var fresh = stale
        fresh.usdPrice = 9
        try await fixture.databaseService.updateTokenPrices([fresh])

        try await fixture.databaseService.saveBalance(
            Balance(account: fixture.account, amount: 30, token: stale, usdValue: nil)
        )

        let stored = try await fixture.storedToken(stale)
        #expect(stored.usdPrice == 9)
        #expect(stored.isWhitelisted)
    }

    @Test func aBalanceSaveKeepsTheStoredIdentityAndImage() async throws {
        let fixture = try await TokenSourceFixture()
        let snapshot = try await fixture.insertToken("1")

        try await fixture.databaseService.markTokenIdentified(snapshot, coinGeckoId: "real-coin")
        let image = URL(string: "https://img.example/a.png")
        try await fixture.databaseService.setTokenMetadata(snapshot, imageURL: image, retryAt: nil)
        try await fixture.databaseService.saveBalance(
            Balance(account: fixture.account, amount: 30, token: snapshot, usdValue: nil)
        )

        let stored = try await fixture.storedToken(snapshot)
        #expect(stored.isWhitelisted)
        #expect(stored.coinGeckoId == "real-coin")
        #expect(stored.imageURL?.absoluteString == "https://img.example/a.png")
    }

    @Test func unidentifiedTokensAreNeitherPricedNorCounted() async throws {
        let fixture = try await TokenSourceFixture()
        let spam = try await fixture.insertToken("1", usdPrice: 1_000)
        try await fixture.insertToken("2", isWhitelisted: true, usdPrice: 2)

        let due = try await fixture.databaseService.fetchTokensDueForPriceUpdate(
            now: .now,
            refreshInterval: 300,
            failureRetryInterval: 600,
            limit: 100
        )

        #expect(!due.contains { $0.token.address == spam.address })
        #expect(due.contains { $0.token.address == TokenSourceFixture.address("2") })

        let balances = try await fixture.databaseService.fetchBalances(accountId: try #require(fixture.account.id))
        #expect(balances.first { $0.token.address == spam.address }?.token.isHidden == true)
        #expect(try await fixture.databaseService.usdValue(accountId: try #require(fixture.account.id)) == 50)
    }
}

private func request(_ token: Token) -> TokenPriceRequest {
    TokenPriceRequest(rpcURL: URL(string: "https://rpc.example")!, token: token)
}

private struct ScriptedSource: PriceSource {
    let id: String
    let price: @Sendable (Token) throws -> Decimal?

    init(id: String, price: @escaping @Sendable (Token) throws -> Decimal?) {
        self.id = id
        self.price = price
    }

    func usdPrice(_ token: Token, rpcURL _: URL) async throws -> Decimal? {
        try price(token)
    }
}
