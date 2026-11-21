// A TON master has several encodings; listings and prices identify it by workchain and hash (ADR-071).

import Foundation
import Moya
import Testing
import WalletKit
@testable import ReefrWallet

struct TonTokenIdentityTests {
    @Test func tonAddressesAreComparedByWorkchainAndHashInAnyEncoding() throws {
        let hash = Data(repeating: 0xAB, count: 32)
        let listed = try TonAddress(workchain: 0, hash: hash, isBounceable: true, isTestOnly: false).string
        let plain = try TonAddress(workchain: 0, hash: hash, isBounceable: false, isTestOnly: false).string
        let raw = try TonAddress(workchain: 0, hash: hash).rawString
        let other = try TonAddress(workchain: 0, hash: Data(repeating: 0xAC, count: 32), isBounceable: true).string

        let listing = TokenListing(
            entries: [TokenListingEntry(address: listed, externalId: "usdt", platform: "the-open-network")],
            fetchedAt: .now
        )

        // Friendly base64 is case-sensitive: lowercasing it must not turn it into a match, or into another address.
        #expect(listing.externalId(platform: "the-open-network", address: plain) == "usdt")
        #expect(listing.externalId(platform: "the-open-network", address: raw) == "usdt")
        #expect(listing.externalId(platform: "the-open-network", address: other) == nil)
        #expect(listing.externalId(platform: "the-open-network", address: listed.lowercased()) == nil)
    }

    @Test func aTonMasterIsAskedAndMatchedInOneCanonicalFormWhateverItsEncoding() throws {
        let hash = Data(repeating: 0x11, count: 32)
        let listed = try TonAddress(workchain: 0, hash: hash, isBounceable: true, isTestOnly: false).string
        let plain = try TonAddress(workchain: 0, hash: hash, isBounceable: false, isTestOnly: false).string
        let raw = try TonAddress(workchain: 0, hash: hash).rawString
        let platform = "the-open-network"

        #expect(CoinGeckoPriceSource.requestAddress(plain, platform: platform) == listed)
        #expect(CoinGeckoPriceSource.requestAddress(raw, platform: platform) == listed)
        #expect(CoinGeckoPriceSource.requestAddress("0xAbC", platform: "ethereum") == "0xAbC")

        // The response may use another encoding than the request.
        #expect(CoinGeckoPriceSource.isSameContract(raw, listed, platform: platform))
        #expect(CoinGeckoPriceSource.isSameContract(plain, listed, platform: platform))
        #expect(!CoinGeckoPriceSource.isSameContract(listed.lowercased(), listed, platform: platform))
        #expect(CoinGeckoPriceSource.isSameContract("0xABC", "0xabc", platform: "ethereum"))
    }

    private let usdtListed = "EQCxE6mUtQJKFnGfaROTKOt1lZbDiiX1kCixRv7Nw2Id_sDs"

    @Test func theProviderKeepsTonJettonsAndTheListingFindsThemByAnyEncoding() throws {
        let json = """
        [
          {"id":"tether","symbol":"usdt","name":"Tether","platforms":
            {"ethereum":"0xdac17f958d2ee523a2206206994597c13d831ec7","the-open-network":"\(usdtListed)"}},
          {"id":"elsewhere","symbol":"x","name":"X","platforms":{"some-unsupported-chain":"abc"}},
          {"id":"empty","symbol":"y","name":"Y","platforms":{"the-open-network":""}}
        ]
        """

        let entries = try CoinGeckoListingProvider.entries(from: Data(json.utf8))
        #expect(entries.contains { $0.platform == "the-open-network" && $0.externalId == "tether" })
        #expect(!entries.contains { $0.platform == "some-unsupported-chain" })
        #expect(!entries.contains { $0.externalId == "empty" })

        let listing = TokenListing(entries: entries, fetchedAt: .now)
        let parsed = try TonAddress(string: usdtListed)
        let raw = parsed.rawString
        let plain = try TonAddress(workchain: parsed.workchain, hash: parsed.hash, isBounceable: false).string

        #expect(listing.externalId(platform: "the-open-network", address: usdtListed) == "tether")
        #expect(listing.externalId(platform: "the-open-network", address: raw) == "tether")
        #expect(listing.externalId(platform: "the-open-network", address: plain) == "tether")
    }

    @Test func aListingCachedBeforeTonWasCoveredIsNotTrustedAsFresh() async throws {
        let old = """
        {"entries":{"ethereum":{"0xabc":"x"}},"fetchedAt":\(Int(Date.now.timeIntervalSince1970))}
        """

        let url = FileManager.default.temporaryDirectory.appending(path: "listing-\(UUID().uuidString).json")
        try Data(old.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        // The file is a fresh listing by its date, but from before TON was covered: it must be fetched again.
        let provider = StubProvider(entries: [
            TokenListingEntry(address: usdtListed, externalId: "tether", platform: "the-open-network")
        ])

        let access = await CachedTokenListing(provider: provider, cacheURL: url).access()
        #expect(provider.fetches.value == 1)
        #expect(access.listing?.externalId(platform: "the-open-network", address: usdtListed) == "tether")
        #expect(ListingIdentitySource(listing: CachedTokenListing(provider: provider), provider: provider)
            .configurationVersion == "listing-2")
    }

    /// A CoinGecko error reply: its status and body, as the transport reports it.
    private func reply(_ status: Int, body: String) -> MoyaError {
        .statusCode(Response(statusCode: status, data: Data(body.utf8)))
    }

    private let sizeRejection = #"{"error_code":10012,"status":{"error_message":"exceeds the allowed limit"}}"#

    @Test func aTonBatchRejectedForItsSizeIsAskedForEachMasterAlone() async {
        let asked = Counter()
        let rejection = reply(400, body: sizeRejection)
        let outcomes = await CoinGeckoPriceSource.tokenOutcomes(["A", "B"], platform: "the-open-network") { addresses in
            await asked.record(addresses)
            return addresses.count == 1 ? .success([addresses[0]: ["usd": 1]]) : .failure(rejection)
        }

        #expect(await asked.requests == [["A", "B"], ["A"], ["B"]])
        #expect(outcomes.allSatisfy { if case .success = $0.1 { true } else { false } })
    }

    @Test func otherFailuresAreNotSplitIntoMoreRequests() async {
        for failure in [
            reply(401, body: #"{"error_code":10002}"#),
            reply(400, body: #"{"error_code":10001}"#),
            reply(503, body: "")
        ] {
            let asked = Counter()

            _ = await CoinGeckoPriceSource.tokenOutcomes(["A", "B"], platform: "the-open-network") { addresses in
                await asked.record(addresses)
                return .failure(failure)
            }

            #expect(await asked.requests == [["A", "B"]])
        }

        let ethereum = Counter()

        _ = await CoinGeckoPriceSource.tokenOutcomes(["A", "B"], platform: "ethereum") { addresses in
            await ethereum.record(addresses)
            return .failure(reply(400, body: sizeRejection))
        }

        #expect(await ethereum.requests == [["A", "B"]])
    }

    @Test func aRateLimitedSingleRetryStopsTheRemainingMasters() async {
        let asked = Counter()
        let rejection = reply(400, body: sizeRejection)
        let limited = reply(429, body: "")

        let outcomes = await CoinGeckoPriceSource.tokenOutcomes(
            ["A", "B", "C"],
            platform: "the-open-network"
        ) { addresses in
            await asked.record(addresses)

            switch addresses {
            case ["A"]: return .success(["A": ["usd": 1]])
            case ["B"]: return .failure(limited)
            default: return .failure(rejection)
            }
        }

        #expect(await asked.requests == [["A", "B", "C"], ["A"], ["B"]])
        #expect(outcomes.count == 3)

        guard case let .failure(error) = outcomes[2].1 else {
            Issue.record("Expected the remaining master to carry the rate limit.")
            return
        }

        #expect(error.isRateLimited)
    }

    @Test func aProviderWideFailureEndsThePassAcrossBatches() async {
        let masters = (0 ..< 51).map { "M\($0)" }
        let batches = CoinGeckoPriceSource.batches(of: masters)
        let rejection = reply(400, body: sizeRejection)

        for failure in [reply(429, body: ""), reply(503, body: "")] {
            let asked = Counter()
            var halt: CoinGeckoPriceSource.PriceOutcome?

            let outcomes = await CoinGeckoPriceSource.tokenOutcomes(
                forBatches: batches,
                platform: "the-open-network",
                halt: &halt
            ) { addresses in
                await asked.record(addresses)
                return addresses.count > 1 ? .failure(rejection) : .failure(failure)
            }

            // The batch, then the first single; master 51 is never asked for, and later passes inherit the halt.
            #expect(await asked.requests == [Array(masters[0 ..< 50]), ["M0"]])
            #expect(outcomes.count == 51)
            #expect(halt != nil)
        }
    }

    @Test func aHaltFromAnEarlierPassMeansNoRequestAtAll() async {
        let asked = Counter()
        var halt: CoinGeckoPriceSource.PriceOutcome? = .failure(reply(429, body: ""))

        let outcomes = await CoinGeckoPriceSource.tokenOutcomes(
            forBatches: [["A"], ["B"]],
            platform: "ethereum",
            halt: &halt
        ) { addresses in
            await asked.record(addresses)
            return .success([:])
        }

        #expect(await asked.requests.isEmpty)
        #expect(outcomes.count == 2)
    }

    private actor Counter {
        var requests: [[String]] = []

        func record(_ addresses: [String]) {
            requests.append(addresses)
        }
    }

    private final class FetchCount: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        var value: Int {
            lock.withLock { count }
        }

        func increment() {
            lock.withLock { count += 1 }
        }
    }

    private struct StubProvider: TokenListingProvider {
        let id = "stub"
        let minimumEntryCount = 0
        let entries: [TokenListingEntry]
        let fetches = FetchCount()

        func fetchEntries() async throws -> [TokenListingEntry] {
            fetches.increment()
            return entries
        }

        func platform(for _: Blockchain) -> String? {
            nil
        }
    }
}
