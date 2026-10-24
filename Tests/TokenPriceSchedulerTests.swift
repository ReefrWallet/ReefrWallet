import Alamofire
import Foundation
import Testing
import WalletKit
@testable import ReefrWallet

@Suite(.serialized, .timeLimit(.minutes(1)))
struct TokenPriceSchedulerTests {
    @Test func pricesHeldAndNativeTokensThenWaitsUntilTheyAreStale() async throws {
        let fixture = try await Fixture(source: ScriptedPriceSource { _ in 2 })

        #expect(await fixture.scheduler.updateDueTokens() == TokenPriceScheduler.idleDelay)

        let tokens = try await fixture.tokens()
        let held = try #require(tokens.first { $0.address == heldTokenAddress })
        let native = try #require(tokens.first { $0.isNativeToken })
        let unheld = try #require(tokens.first { $0.address == unheldTokenAddress })

        for token in [held, native] {
            #expect(token.priceSourceId == ScriptedPriceSource.id)
            #expect(token.usdPrice == 2)
            #expect(token.priceUpdatedAt != nil)
            #expect(!token.hasPriceFetchError)
        }

        #expect(unheld.priceUpdatedAt == nil)
        #expect(try await fixture.dueAddresses(after: 0).isEmpty)
        #expect(try await fixture.dueAddresses(after: TokenPriceScheduler.refreshInterval + 1).count == 2)
    }

    @Test func failedFetchIsStampedAndRetriedLater() async throws {
        let fixture = try await Fixture(source: ScriptedPriceSource { _ in throw TestError.failed })

        _ = await fixture.scheduler.updateDueTokens()

        let held = try #require(try await fixture.tokens().first { $0.address == heldTokenAddress })
        #expect(held.hasPriceFetchError)
        #expect(held.priceUpdatedAt != nil)
        #expect(held.usdPrice == nil)
        #expect(try await fixture.dueAddresses(after: TokenPriceScheduler.refreshInterval + 1).isEmpty)
        #expect(try await fixture.dueAddresses(after: TokenPriceScheduler.failureRetryInterval + 1).count == 2)
    }

    @Test func failedFetchForgetsTheSourceButKeepsThePrice() async throws {
        let isFailing = Flag(false)

        let fixture = try await Fixture(source: ScriptedPriceSource { _ in
            guard !isFailing.value else {
                throw TestError.failed
            }

            return 3
        })

        _ = await fixture.scheduler.updateDueTokens()
        isFailing.value = true
        let later = Date.now.addingTimeInterval(TokenPriceScheduler.refreshInterval + 1)
        _ = await fixture.scheduler.updateDueTokens(now: later)

        let held = try #require(try await fixture.tokens().first { $0.address == heldTokenAddress })
        #expect(held.hasPriceFetchError)
        #expect(held.priceSourceId == nil)
        #expect(held.usdPrice == 3)
    }

    @Test func staleTokensAreOrderedOldestFirst() async throws {
        let fixture = try await Fixture(source: ScriptedPriceSource { token in
            guard token.isNativeToken else {
                throw TestError.failed
            }

            return 1
        })

        _ = await fixture.scheduler.updateDueTokens()

        let expected = try await fixture.tokens()
            .filter { $0.priceUpdatedAt != nil }
            .sorted { ($0.priceUpdatedAt ?? .distantPast) < ($1.priceUpdatedAt ?? .distantPast) }
            .map(\.address)

        #expect(expected.count == 2)
        #expect(try await fixture.dueAddresses(after: TokenPriceScheduler.failureRetryInterval + 1) == expected)
    }

    @Test func rateLimitingBacksOffExponentiallyAndRecovers() async throws {
        let isRateLimited = Flag(true)

        let fixture = try await Fixture(source: ScriptedPriceSource { _ in
            guard !isRateLimited.value else {
                throw AFError.responseValidationFailed(reason: .unacceptableStatusCode(code: 429))
            }

            return 1
        })

        #expect(await fixture.scheduler.updateDueTokens() == TokenPriceScheduler.minRateLimitBackoff)
        #expect(await fixture.scheduler.updateDueTokens() == TokenPriceScheduler.minRateLimitBackoff * 2)

        isRateLimited.value = false
        let later = Date.now.addingTimeInterval(TokenPriceScheduler.failureRetryInterval + 1)
        #expect(await fixture.scheduler.updateDueTokens(now: later) == TokenPriceScheduler.idleDelay)
    }
}

private let heldTokenAddress = "0x2::held::HELD"
private let unheldTokenAddress = "0x2::unheld::UNHELD"

private struct Fixture {
    static let blockchain = Blockchain.sui(.testnet)

    let databaseService: DatabaseService
    let scheduler: TokenPriceScheduler

    init(source: any PriceSource) async throws {
        databaseService = try makeDatabaseService()

        let keyStore = try await databaseService.watchOnlyKeyStore()

        var account = Account(
            address: "0x0000000000000000000000000000000000000000000000000000000000000001",
            blockchain: Self.blockchain,
            derivationPath: nil,
            keyStoreId: try #require(keyStore.id),
            name: "Price Test"
        )

        account.id = try await databaseService.insertAccount(account, keyStore: keyStore)

        let held = Self.makeToken(address: heldTokenAddress)
        _ = try await databaseService.insertToken(held, blockchain: Self.blockchain)
        try await databaseService.saveBalance(Balance(account: account, amount: 25, token: held, usdValue: nil))
        let unheld = Self.makeToken(address: unheldTokenAddress)
        _ = try await databaseService.insertToken(unheld, blockchain: Self.blockchain)

        scheduler = TokenPriceScheduler(
            databaseService: databaseService,
            priceService: TokenPriceService(databaseService: databaseService, sources: [source])
        )
    }

    func dueAddresses(after interval: TimeInterval) async throws -> [String?] {
        try await databaseService.fetchTokensDueForPriceUpdate(
            now: .now.addingTimeInterval(interval),
            refreshInterval: TokenPriceScheduler.refreshInterval,
            failureRetryInterval: TokenPriceScheduler.failureRetryInterval,
            limit: TokenPriceScheduler.batchSize
        ).map(\.token.address)
    }

    func tokens() async throws -> [Token] {
        try await databaseService.fetchTokens(blockchain: Self.blockchain)
    }

    static func makeToken(address: String) -> Token {
        Token(
            address: address,
            blockchain: Self.blockchain,
            coinGeckoId: nil,
            decimalsCount: 9,
            imageURL: nil,
            isHidden: false,
            isIncludedInBalance: true,
            isNativeToken: false,
            name: address,
            symbol: address,
            usdPrice: nil
        )
    }
}

private final class Flag: @unchecked Sendable {
    var value: Bool

    init(_ value: Bool) {
        self.value = value
    }
}

private struct ScriptedPriceSource: PriceSource {
    static let id = "scripted"

    let price: @Sendable (Token) throws -> Decimal?

    var id: String {
        Self.id
    }

    func usdPrice(_ token: Token, rpcURL _: URL) async throws -> Decimal? {
        try price(token)
    }
}

private enum TestError: Swift.Error {
    case failed
}
