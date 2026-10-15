import Foundation
import Moya
import Testing
import WalletKit
@testable import ReefrWallet

@Suite(.serialized, .timeLimit(.minutes(1)))
struct TokenPriceServiceTests {
    @Test func usesTheFirstApplicableSource() async throws {
        let service = TokenPriceService(sources: [
            StubPriceSource(price: 1),
            StubPriceSource(price: 2)
        ])

        let price = try await service.usdPrice(testToken, rpcURL: testRPCURL)

        #expect(price == 1)
    }

    @Test func continuesAfterASourceFailure() async throws {
        let service = TokenPriceService(sources: [
            StubPriceSource(shouldThrow: true),
            StubPriceSource(price: 2)
        ])

        let price = try await service.usdPrice(testToken, rpcURL: testRPCURL)

        #expect(price == 2)
    }

    @Test func continuesWhenASourceDoesNotSupportTheRequest() async throws {
        let service = TokenPriceService(sources: [
            StubPriceSource(),
            StubPriceSource(price: 2)
        ])

        let price = try await service.usdPrice(testToken, rpcURL: testRPCURL)

        #expect(price == 2)
    }

    @Test func failsWhenNoSourceSupportsTheRequest() async {
        let service = TokenPriceService(sources: [StubPriceSource()])

        await #expect(throws: WalletKitError.self) {
            _ = try await service.usdPrice(testToken, rpcURL: testRPCURL)
        }
    }

    @Test func cetusDoesNotAttemptAQuoteOutsideSuiMainnet() async throws {
        let source = CetusPriceSource(clientProvider: BlockchainClientProvider())

        let price = try await source.usdPrice(testToken, rpcURL: testRPCURL)

        #expect(price == nil)
    }

    @Test func coinGeckoQuotesEverySupportedMainnetNativeAsset() async throws {
        let source = CoinGeckoPriceSource(apiKey: "demo-key", baseURL: testAPIURL, provider: coinGeckoProvider())

        for blockchain in Blockchain.allMainnets {
            guard !blockchain.isCustomEVM else {
                continue
            }

            let token = Token(address: nil, blockchain: blockchain, tokenInfo: blockchain.nativeToken)
            #expect(try await source.usdPrice(token, rpcURL: testRPCURL) == 1)
        }
    }

    @Test func coinGeckoUsesTheContractPriceEndpointForTokens() async throws {
        let source = CoinGeckoPriceSource(apiKey: "demo-key", baseURL: testAPIURL, provider: coinGeckoProvider())
        let address = "0xABC def"
        let token = Token(
            address: address,
            blockchain: .evm(.ethereum(.mainnet)),
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

        #expect(try await source.usdPrice(token, rpcURL: testRPCURL) == 1)
        let target = CoinGeckoAPI.tokenPrice(
            address: address,
            apiKey: "demo-key",
            baseURL: testAPIURL,
            platform: "ethereum"
        )
        #expect(target.path == "simple/token_price/ethereum")
        #expect(target.headers?["x-cg-demo-api-key"] == "demo-key")
    }

    @Test func coinGeckoQuotesTokensOnEverySupportedMainnet() async throws {
        let source = CoinGeckoPriceSource(apiKey: "demo-key", baseURL: testAPIURL, provider: coinGeckoProvider())

        for blockchain in Blockchain.allMainnets {
            guard blockchain != .bitcoin(.mainnet), !blockchain.isCustomEVM else {
                continue
            }

            let token = Token(
                address: "token-address",
                blockchain: blockchain,
                coinGeckoId: nil,
                decimalsCount: 6,
                imageURL: nil,
                isHidden: false,
                isIncludedInBalance: true,
                isNativeToken: false,
                name: "Token",
                symbol: "TOK",
                usdPrice: nil
            )
            #expect(try await source.usdPrice(token, rpcURL: testRPCURL) == 1)
        }
    }

    @Test func coinGeckoSkipsTestnetsAndUnlistedAssets() async throws {
        let source = CoinGeckoPriceSource(apiKey: "demo-key", baseURL: testAPIURL, provider: coinGeckoProvider())
        let testnetToken = Token(address: nil, blockchain: .solana(.devnet), tokenInfo: .solana)

        #expect(try await source.usdPrice(testnetToken, rpcURL: testRPCURL) == nil)
        let mainnetToken = Token(address: nil, blockchain: .bitcoin(.mainnet), tokenInfo: .bitcoin)
        let unlistedSource = CoinGeckoPriceSource(
            apiKey: "demo-key",
            baseURL: testAPIURL,
            provider: coinGeckoProvider(response: Data(#"{}"#.utf8))
        )
        #expect(try await unlistedSource.usdPrice(mainnetToken, rpcURL: testRPCURL) == nil)
    }

    @Test func coinGeckoRejectsInvalidPrices() async {
        let source = CoinGeckoPriceSource(
            apiKey: "demo-key",
            baseURL: testAPIURL,
            provider: coinGeckoProvider(response: Data(#"{"bitcoin":{"usd":0}}"#.utf8))
        )

        let token = Token(address: nil, blockchain: .bitcoin(.mainnet), tokenInfo: .bitcoin)

        await #expect(throws: Error.self) {
            _ = try await source.usdPrice(token, rpcURL: testRPCURL)
        }
    }
}

private struct StubPriceSource: PriceSource {
    let shouldThrow: Bool
    let value: Decimal?

    init(shouldThrow: Bool = false, price: Decimal? = nil) {
        self.shouldThrow = shouldThrow
        value = price
    }

    func usdPrice(_ token: Token, rpcURL: URL) async throws -> Decimal? {
        if shouldThrow {
            throw StubError.failed
        }

        return value
    }
}

private enum StubError: Swift.Error {
    case failed
}

private let testToken = Token(
    address: nil,
    blockchain: .sui(.testnet),
    tokenInfo: .sui
)

private let testRPCURL = Blockchain.sui(.testnet).rpcURL
private let testAPIURL = URL(string: "https://api.example/api/v3")!

private func coinGeckoProvider(response: Data? = nil) -> MoyaProvider<CoinGeckoAPI> {
    MoyaProvider(
        endpointClosure: { target in
            let key: String
            switch target {
            case let .nativePrice(_, _, coinGeckoId):
                key = coinGeckoId
            case let .tokenPrice(address, _, _, _):
                key = address
            }

            return Endpoint(
                url: target.baseURL.appending(path: target.path).absoluteString,
                sampleResponseClosure: { .networkResponse(200, response ?? Data("{\"\(key)\":{\"usd\":1}}".utf8)) },
                method: target.method,
                task: target.task,
                httpHeaderFields: target.headers
            )
        },
        stubClosure: MoyaProvider.immediatelyStub
    )
}
