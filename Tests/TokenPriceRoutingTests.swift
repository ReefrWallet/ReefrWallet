import Foundation
import Moya
import Testing
import WalletKit
@testable import ReefrWallet

@Suite(.serialized, .timeLimit(.minutes(1)))
struct TokenPriceRoutingTests {
    // MARK: Routes

    @Test func chainsWithoutRoutesOnlyReachUniversalSources() async {
        let log = CallLog()

        let routes = PriceRoutes(
            chains: [.evm(.ethereum(.mainnet)): [RecordingSource(id: "ethereum", log: log)]],
            universal: [RecordingSource(id: "universal", log: log)]
        )

        _ = await TokenPriceService(routes: routes).resolvedPrices([request(erc20(on: .evm(.base(.mainnet))))])

        #expect(log.visited == ["universal"])
    }

    @Test func liveRoutesCoverTheConfiguredChains() {
        let routes = PriceRoutes.live(clientProvider: BlockchainClientProvider())
        let full = ["chainlink", "uniswapV3", "coinGecko"]

        for blockchain in [Blockchain.evm(.arbitrum(.mainnet)), .evm(.ethereum(.mainnet)), .evm(.robinhood(.mainnet))] {
            #expect(routes.sources(for: blockchain).map(\.id) == full)
        }

        #expect(routes.sources(for: .evm(.hyperEVM(.mainnet))).map(\.id) == ["chainlink", "coinGecko"])
        #expect(routes.sources(for: .evm(.mantle(.mainnet))).map(\.id) == ["chainlink", "coinGecko"])
        #expect(routes.sources(for: .sui(.mainnet)).map(\.id) == ["cetus", "coinGecko"])
        #expect(routes.sources(for: .evm(.ethereum(.sepolia))).map(\.id) == ["coinGecko"])
        #expect(routes.sources(for: .bitcoin(.mainnet)).map(\.id) == ["coinGecko"])
    }

    @Test func liveRoutesNormalizeKnownCustomChains() {
        let routes = PriceRoutes.live(clientProvider: BlockchainClientProvider())

        #expect(routes.sources(for: .evm(.custom(1))).map(\.id) == ["chainlink", "uniswapV3", "coinGecko"])
        #expect(routes.sources(for: .evm(.custom(11_155_111))).map(\.id) == ["coinGecko"])
        #expect(routes.sources(for: .evm(.custom(999_999))).map(\.id) == ["coinGecko"])
    }

    @Test func tokensReachOnlyTheirOwnChainsRoute() async {
        let log = CallLog()

        let routes = PriceRoutes(
            chains: [
                .evm(.arbitrum(.mainnet)): [RecordingSource(id: "arbitrum", log: log)],
                .evm(.ethereum(.mainnet)): [RecordingSource(id: "ethereum", log: log)],
                .sui(.mainnet): [RecordingSource(id: "sui", log: log)]
            ],
            universal: [RecordingSource(id: "universal", log: log)]
        )

        let service = TokenPriceService(routes: routes)

        for (blockchain, expected) in [
            (Blockchain.evm(.arbitrum(.mainnet)), ["arbitrum", "universal"]),
            (.evm(.ethereum(.mainnet)), ["ethereum", "universal"]),
            (.sui(.mainnet), ["sui", "universal"])
        ] {
            log.reset()
            _ = await service.resolvedPrices([request(erc20(on: blockchain))])
            #expect(log.visited == expected)
        }
    }

    @Test func aStoredSourceOutsideTheRouteIsIgnored() async {
        let log = CallLog()

        let routes = PriceRoutes(
            chains: [.evm(.arbitrum(.mainnet)): [RecordingSource(id: "arbitrum", log: log)]],
            universal: [RecordingSource(id: "universal", log: log)]
        )

        var token = erc20(on: .evm(.base(.mainnet)))
        token.priceSourceId = "arbitrum"
        _ = await TokenPriceService(routes: routes).resolvedPrices([request(token)])

        #expect(log.visited == ["universal"])
    }

    // MARK: Chainlink

    @Test func chainlinkAcceptsAnAnswerExactlyAtTheMaximumAge() async throws {
        let result = await chainlinkResult(updatedAt: now - 3_600 - 900)

        #expect(try result.get() == 2_000)
    }

    @Test func chainlinkRejectsAStaleAnswer() async {
        let result = await chainlinkResult(updatedAt: now - 3_600 - 901)

        #expect(isStale(result))
    }

    @Test func chainlinkRejectsAnAnswerThatWasNeverUpdated() async {
        #expect(isStale(await chainlinkResult(updatedAt: 0)))
    }

    @Test func chainlinkAcceptsClockSkewUpToFiveMinutes() async throws {
        let result = await chainlinkResult(updatedAt: now + 300)

        #expect(try result.get() == 2_000)
    }

    @Test func chainlinkRejectsTimestampsBeyondTheSkewAllowance() async {
        #expect(isStale(await chainlinkResult(updatedAt: now + 301)))
        #expect(isStale(await chainlinkResult(updatedAt: now + 10_000_000)))
    }

    @Test func ethereumFeedsAllowTwentyFourHoursPlusGrace() async throws {
        let fresh = await ethereumUSDCResult(updatedAt: now - 86_400 - 900)
        let stale = await ethereumUSDCResult(updatedAt: now - 86_400 - 901)

        #expect(try fresh.get() == 2_000)
        #expect(isStale(stale))
    }

    @Test func ethereumFeedsComeFromTheAddressTableNeverFromTheSymbol() async throws {
        let stub = chainlinkStub(updatedAt: now)
        let source = ethereumChainlinkSource(stub)
        let usdc = erc20(on: ethereum, address: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48")

        #expect(try await source.usdPrice(usdc, rpcURL: stub.endpoint) == 2_000)
        #expect(Set(stub.calls().map(\.to)) == ["0x8fffffd4afb6115b954bd326cbe7b4ba576818f6"])

        var squatter = erc20(on: ethereum, address: "0x" + String(repeating: "99", count: 20))
        squatter.symbol = "USDC"
        let callCount = stub.calls().count

        #expect(try await source.usdPrice(squatter, rpcURL: stub.endpoint) == nil)
        #expect(stub.calls().count == callCount)
    }

    @Test func chainlinkReadsTheNativeFeedForNativeTokens() async throws {
        let stub = chainlinkStub(updatedAt: now)
        let source = chainlinkSource(stub)
        let token = Token(address: nil, blockchain: arbitrum, tokenInfo: arbitrum.nativeToken)

        #expect(try await source.usdPrice(token, rpcURL: stub.endpoint) == 2_000)
        #expect(Set(stub.calls().map(\.to)) == [nativeFeed.address])
    }

    @Test func chainlinkReadsTheTokenFeedForContractTokensRegardlessOfAddressCase() async throws {
        let stub = chainlinkStub(updatedAt: now)
        let source = chainlinkSource(stub)
        let token = erc20(on: arbitrum, address: listedAddress.uppercased().replacingOccurrences(of: "0X", with: "0x"))

        #expect(try await source.usdPrice(token, rpcURL: stub.endpoint) == 2_000)
        #expect(Set(stub.calls().map(\.to)) == [tokenFeed.address])
    }

    @Test func chainlinkSkipsUnlistedTokensWithoutAnyRPCCall() async throws {
        let stub = chainlinkStub(updatedAt: now)
        let source = chainlinkSource(stub)
        var spoof = erc20(on: arbitrum, address: "0x" + String(repeating: "99", count: 20))
        spoof.symbol = "ETH"

        #expect(try await source.usdPrice(spoof, rpcURL: stub.endpoint) == nil)
        #expect(stub.calls().isEmpty)
    }

    @Test func aStaleChainlinkAnswerFallsThroughToTheNextSource() async throws {
        let stub = chainlinkStub(updatedAt: now - 100_000)
        let log = CallLog()

        let routes = PriceRoutes(
            chains: [arbitrum: [chainlinkSource(stub), RecordingSource(id: "next", log: log, price: 7)]],
            universal: []
        )

        let token = Token(address: nil, blockchain: arbitrum, tokenInfo: arbitrum.nativeToken)
        let price = try await TokenPriceService(routes: routes).resolvedPrice(token, rpcURL: stub.endpoint)

        #expect(price.sourceId == "next")
        #expect(price.usdPrice == 7)
    }

    // MARK: Uniswap

    @Test func uniswapQueriesTheInjectedFactoryWithTheInjectedQuote() async throws {
        let tokenAddress = "0x" + String(repeating: "33", count: 20)

        struct Expected {
            let deployment: UniswapV3PriceSource.Deployment
            let factory: String
            let quote: String
        }

        let deployments = [
            Expected(
                deployment: .arbitrum,
                factory: "0x1f98431c8ad98523631ae4a59f267346ea31f984",
                quote: "0xaf88d065e77c8cc2239327c5edb3a432268e5831"
            ),
            Expected(
                deployment: .robinhood,
                factory: "0x1f7d7550b1b028f7571e69a784071f0205fd2efa",
                quote: "0x5fc5360d0400a0fd4f2af552add042d716f1d168"
            )
        ]

        for expected in deployments {
            let (deployment, factory, quote) = (expected.deployment, expected.factory, expected.quote)

            let stub = EthereumStubURLProtocol.make { _ in "0x" + String(repeating: "0", count: 64) }
            let source = UniswapV3PriceSource(
                clientProvider: BlockchainClientProvider(urlSession: stub.session),
                deployment: deployment
            )

            await #expect(throws: TokenNotListed.self) {
                _ = try await source.usdPrice(erc20(on: arbitrum, address: tokenAddress), rpcURL: stub.endpoint)
            }

            let calls = stub.calls()
            #expect(calls.count == 4)
            #expect(Set(calls.map(\.to)) == [factory])
            #expect(calls.allSatisfy { $0.data.hasPrefix("0x1698ee82") })
            #expect(calls.allSatisfy { $0.data.contains(tokenAddress.dropFirst(2)) })
            #expect(calls.allSatisfy { $0.data.contains(quote.dropFirst(2)) })
        }
    }

    // MARK: CoinGecko

    @Test func coinGeckoBatchesMixedChainsPerPlatformAndFallsBackForUnlistedTokens() async {
        let log = CallLog()
        let paths = PathLog()
        let provider = coinGeckoProvider(paths: paths) { !$0.contains("0xb2") }
        let source = CoinGeckoPriceSource(apiKey: "demo-key", baseURL: testAPIURL, provider: provider)

        let routes = PriceRoutes(
            chains: [arbitrum: [RecordingSource(id: "arbitrum", log: log)]],
            universal: [source, RecordingSource(id: "after", log: log, price: 5)]
        )

        let results = await TokenPriceService(routes: routes).resolvedPrices([
            request(erc20(on: arbitrum, address: "0xa1")),
            request(erc20(on: arbitrum, address: "0xb2")),
            request(erc20(on: .evm(.ethereum(.mainnet)), address: "0xc3"))
        ])

        #expect(results.map { try? $0.get().sourceId } == ["coinGecko", "after", "coinGecko"])
        #expect(results.map { try? $0.get().usdPrice } == [1, 5, 1])
        #expect(paths.sorted == ["simple/token_price/arbitrum-one", "simple/token_price/ethereum"])
    }

    @Test func coinGeckoRequestsRobinhoodTokensOnTheRobinhoodPlatform() async throws {
        let paths = PathLog()
        let source = CoinGeckoPriceSource(
            apiKey: "demo-key",
            baseURL: testAPIURL,
            provider: coinGeckoProvider(paths: paths) { _ in true }
        )

        let token = erc20(on: .evm(.robinhood(.mainnet)), address: "0xd4")

        #expect(try await source.usdPrice(token, rpcURL: testRPCURL) == 1)
        #expect(paths.sorted == ["simple/token_price/robinhood"])
    }
}

// MARK: - Helpers

private let arbitrum = Blockchain.evm(.arbitrum(.mainnet))
private let now: UInt64 = 1_800_000_000
private let testAPIURL = URL(string: "https://api.example/api/v3")!
private let testRPCURL = URL(string: "https://rpc.example")!
private let listedAddress = "0x" + String(repeating: "ab", count: 20)

private let nativeFeed = ChainlinkPriceSource.Feed(address: "0x" + String(repeating: "cd", count: 20), heartbeat: 3_600)
private let tokenFeed = ChainlinkPriceSource.Feed(address: "0x" + String(repeating: "ef", count: 20), heartbeat: 3_600)

private func capture<T>(_ work: () async throws -> T) async -> Result<T, any Swift.Error> {
    do {
        return .success(try await work())
    } catch {
        return .failure(error)
    }
}

private func chainlinkSource(
    _ stub: EthereumStubURLProtocol.Stub,
    lookup: ChainlinkPriceSource.FeedLookup? = nil
) -> ChainlinkPriceSource {
    ChainlinkPriceSource(
        clientProvider: BlockchainClientProvider(urlSession: stub.session),
        lookup: lookup ?? .table(native: nativeFeed, tokens: [listedAddress: tokenFeed]),
        now: { Date(timeIntervalSince1970: TimeInterval(now)) }
    )
}

private func chainlinkResult(updatedAt: UInt64) async -> Result<Decimal?, any Swift.Error> {
    let stub = chainlinkStub(updatedAt: updatedAt)
    let token = Token(address: nil, blockchain: arbitrum, tokenInfo: arbitrum.nativeToken)

    return await capture { try await chainlinkSource(stub).usdPrice(token, rpcURL: stub.endpoint) }
}

private let ethereum = Blockchain.evm(.ethereum(.mainnet))

private func ethereumChainlinkSource(_ stub: EthereumStubURLProtocol.Stub) -> ChainlinkPriceSource {
    ChainlinkPriceSource(
        clientProvider: BlockchainClientProvider(urlSession: stub.session),
        lookup: .ethereum,
        now: { Date(timeIntervalSince1970: TimeInterval(now)) }
    )
}

private func ethereumUSDCResult(updatedAt: UInt64) async -> Result<Decimal?, any Swift.Error> {
    let stub = chainlinkStub(updatedAt: updatedAt)
    let usdc = erc20(on: ethereum, address: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48")

    return await capture { try await ethereumChainlinkSource(stub).usdPrice(usdc, rpcURL: stub.endpoint) }
}

private func chainlinkStub(updatedAt: UInt64) -> EthereumStubURLProtocol.Stub {
    EthereumStubURLProtocol.make { roundOrDecimals($0, updatedAt: updatedAt) }
}

private func roundOrDecimals(_ call: EthereumStubURLProtocol.Call, updatedAt: UInt64) -> String? {
    switch call.data.prefix(10) {
    // latestRoundData(): roundId, answer ($2000 at 8 decimals), startedAt, updatedAt, answeredInRound
    case "0xfeaf968c": "0x" + [1, 200_000_000_000, updatedAt, updatedAt, 1].map(word).joined()
    // decimals()
    case "0x313ce567": "0x" + word(8)
    default: nil
    }
}

private func word(_ value: UInt64) -> String {
    let hex = String(value, radix: 16)
    return String(repeating: "0", count: 64 - hex.count) + hex
}

private func isStale(_ result: Result<Decimal?, any Swift.Error>) -> Bool {
    guard case let .failure(error) = result else {
        return false
    }

    return error is ChainlinkPriceSource.StaleAnswer
}

private func erc20(on blockchain: Blockchain, address: String = "0xdead") -> Token {
    Token(
        address: address,
        blockchain: blockchain,
        coinGeckoId: nil,
        decimalsCount: 18,
        imageURL: nil,
        isHidden: false,
        isIncludedInBalance: true,
        isNativeToken: false,
        name: "Token",
        symbol: "TOK",
        usdPrice: nil
    )
}

private func request(_ token: Token) -> TokenPriceRequest {
    TokenPriceRequest(rpcURL: testRPCURL, token: token)
}

private final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String] = []

    var visited: [String] {
        lock.withLock { ids }
    }

    func record(_ id: String) {
        lock.withLock { ids.append(id) }
    }

    func reset() {
        lock.withLock { ids = [] }
    }
}

private final class PathLog: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: Set<String> = []

    var sorted: [String] {
        lock.withLock { paths.sorted() }
    }

    func record(_ path: String) {
        lock.withLock { _ = paths.insert(path) }
    }
}

private struct RecordingSource: PriceSource {
    let id: String
    let log: CallLog
    var price: Decimal?

    init(id: String, log: CallLog, price: Decimal? = nil) {
        self.id = id
        self.log = log
        self.price = price
    }

    func usdPrice(_ token: Token, rpcURL: URL) async throws -> Decimal? {
        log.record(id)
        return price
    }
}

/// Answers `$1` for every requested id or address that `isListed` accepts (given lowercased).
private func coinGeckoProvider(
    paths: PathLog,
    isListed: @escaping @Sendable (String) -> Bool
) -> MoyaProvider<CoinGeckoAPI> {
    MoyaProvider(
        endpointClosure: { target in
            paths.record(target.path)

            let keys: [String]
            switch target {
            case let .nativePrice(_, _, coinGeckoIds):
                keys = coinGeckoIds
            case let .tokenPrice(addresses, _, _, _):
                keys = addresses
            }

            let body = "{" + keys.filter { isListed($0.lowercased()) }.map { "\"\($0)\":{\"usd\":1}" }
                .joined(separator: ",") + "}"

            return Endpoint(
                url: target.baseURL.appending(path: target.path).absoluteString,
                sampleResponseClosure: { .networkResponse(200, Data(body.utf8)) },
                method: target.method,
                task: target.task,
                httpHeaderFields: target.headers
            )
        },
        stubClosure: MoyaProvider.immediatelyStub
    )
}
