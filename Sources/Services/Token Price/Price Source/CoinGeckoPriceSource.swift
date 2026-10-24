import Alamofire
import Foundation
@preconcurrency import Moya
import WalletKit

/// CoinGecko's aggregated market-data fallback for mainnet assets.
struct CoinGeckoPriceSource: PriceSource {
    static let apiKeyDefaultsKey = "CoinGeckoAPIKey"
    static let defaultBaseURL = URL(string: "https://api.coingecko.com/api/v3")!

    private let apiKey: String?
    private let baseURL: URL
    private let provider: CoinGeckoProvider

    init(
        apiKey: String? = CoinGeckoPriceSource.configuredAPIKey(),
        baseURL: URL = CoinGeckoPriceSource.defaultBaseURL,
        provider: MoyaProvider<CoinGeckoAPI>? = nil
    ) {
        self.apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.baseURL = baseURL

        self.provider = CoinGeckoProvider(provider ?? MoyaProvider(session: Session(
            interceptor: CoinGeckoRateLimitInterceptor.shared
        )))
    }

    var id: String {
        "coinGecko"
    }

    func usdPrice(_ token: Token, rpcURL: URL) async throws -> Decimal? {
        try await resolvedPrice(token, rpcURL: rpcURL)?.usdPrice
    }

    func resolvedPrice(_ token: Token, rpcURL _: URL) async throws -> CoinGeckoPrice? {
        guard let apiKey, !apiKey.isEmpty else {
            printVerbose("CoinGecko skipped: no API key (defaults '\(Self.apiKeyDefaultsKey)' / env COINGECKO_API_KEY)")
            return nil
        }

        guard let identifier = identifier(for: token) else {
            printVerbose("CoinGecko skipped: no identifier for \(token.symbol) (non-mainnet or unmapped chain)")
            return nil
        }

        printVerbose("CoinGecko request: \(identifier)")

        let response: [String: [String: Decimal]]

        switch identifier {
        case let .native(coinGeckoId):
            response = try await provider.value.request(.nativePrice(
                apiKey: apiKey,
                baseURL: baseURL,
                coinGeckoId: coinGeckoId
            ))

            guard let usdPrice = response[coinGeckoId]?["usd"] else {
                return nil
            }

            return try resolvedPrice(usdPrice, coinGeckoId: coinGeckoId)
        case let .token(platform, address):
            response = try await provider.value.request(.tokenPrice(
                address: address,
                apiKey: apiKey,
                baseURL: baseURL,
                platform: platform
            ))

            guard let usdPrice = response.first(where: {
                $0.key.caseInsensitiveCompare(address) == .orderedSame
            })?.value["usd"] else {
                return nil
            }

            return try resolvedPrice(usdPrice, coinGeckoId: nil)
        }
    }
}

private extension CoinGeckoPriceSource {
    enum AssetIdentifier {
        case native(String)
        case token(platform: String, address: String)
    }

    static func configuredAPIKey() -> String? {
        let setting = UserDefaults.standard.string(forKey: apiKeyDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let setting, !setting.isEmpty {
            return setting
        }

        return ProcessInfo.processInfo.environment["COINGECKO_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func identifier(for token: Token) -> AssetIdentifier? {
        guard let blockchain = token.blockchain, blockchain.isMainnet else {
            return nil
        }

        if token.isNativeToken {
            guard let coinGeckoId = token.coinGeckoId ?? nativeCoinGeckoId(for: blockchain) else {
                return nil
            }

            return .native(coinGeckoId)
        }

        guard let address = token.address, let platform = assetPlatform(for: blockchain) else {
            return nil
        }

        return .token(platform: platform, address: address)
    }

    func nativeCoinGeckoId(for blockchain: Blockchain) -> String? {
        switch blockchain {
        case .aptos: "aptos"
        case .bitcoin: "bitcoin"
        case .cardano: "cardano"
        case let .evm(chain):
            switch chain {
            case .arbitrum, .base, .ethereum, .optimism, .robinhood, .unichain: "ethereum"
            case .avalanche: "avalanche-2"
            case .bsc: "binancecoin"
            case .hyperEVM: "hyperliquid"
            case .mantle: "mantle"
            case .monad: "monad"
            case .polygon: "polygon-ecosystem-token"
            case .custom: nil
            }

        case .solana: "solana"
        case .sui: "sui"
        case .tron: "tron"
        }
    }

    func assetPlatform(for blockchain: Blockchain) -> String? {
        switch blockchain {
        case .aptos: "aptos"
        case .bitcoin: nil
        case .cardano: "cardano"
        case let .evm(chain):
            switch chain {
            case .arbitrum: "arbitrum-one"
            case .avalanche: "avalanche"
            case .base: "base"
            case .bsc: "binance-smart-chain"
            case .ethereum: "ethereum"
            case .hyperEVM: "hyperevm"
            case .mantle: "mantle"
            case .monad: "monad"
            case .optimism: "optimistic-ethereum"
            case .polygon: "polygon-pos"
            case .robinhood: "robinhood-chain"
            case .unichain: "unichain"
            case .custom: nil
            }

        case .solana: "solana"
        case .sui: "sui"
        case .tron: "tron"
        }
    }

    func resolvedPrice(_ usdPrice: Decimal, coinGeckoId: String?) throws -> CoinGeckoPrice {
        guard usdPrice > 0, !usdPrice.isNaN else {
            throw ReefrError.invalidData
        }

        return CoinGeckoPrice(coinGeckoId: coinGeckoId, usdPrice: usdPrice)
    }
}

struct CoinGeckoPrice: Sendable {
    let coinGeckoId: String?
    let usdPrice: Decimal
}

private final class CoinGeckoProvider: @unchecked Sendable {
    let value: MoyaProvider<CoinGeckoAPI>

    init(_ value: MoyaProvider<CoinGeckoAPI>) {
        self.value = value
    }
}

enum CoinGeckoAPI {
    case nativePrice(apiKey: String, baseURL: URL, coinGeckoId: String)
    case tokenPrice(address: String, apiKey: String, baseURL: URL, platform: String)
}

extension CoinGeckoAPI: TargetType {
    var baseURL: URL {
        switch self {
        case let .nativePrice(_, baseURL, _), let .tokenPrice(_, _, baseURL, _): baseURL
        }
    }

    var headers: [String: String]? {
        switch self {
        case let .nativePrice(apiKey, _, _), let .tokenPrice(_, apiKey, _, _):
            ["x-cg-demo-api-key": apiKey]
        }
    }

    var method: Moya.Method {
        .get
    }

    var path: String {
        switch self {
        case .nativePrice: "simple/price"
        case let .tokenPrice(_, _, _, platform): "simple/token_price/\(platform)"
        }
    }

    var sampleData: Data {
        Data()
    }

    var task: Task {
        switch self {
        case let .nativePrice(_, _, coinGeckoId):
            .requestParameters(
                parameters: ["ids": coinGeckoId, "precision": "full", "vs_currencies": "usd"],
                encoding: URLEncoding.queryString
            )

        case let .tokenPrice(address, _, _, _):
            .requestParameters(
                parameters: ["contract_addresses": address, "precision": "full", "vs_currencies": "usd"],
                encoding: URLEncoding.queryString
            )
        }
    }

    var validationType: ValidationType {
        .successCodes
    }
}
