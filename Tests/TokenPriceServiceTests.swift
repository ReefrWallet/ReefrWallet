import Testing
import WalletKit
@testable import ReefrWallet

@Suite(.timeLimit(.minutes(1)))
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
