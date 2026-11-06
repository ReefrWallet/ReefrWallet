import Alamofire
import Foundation
@preconcurrency import Moya
import WalletKit

/// CoinGecko's aggregated market-data fallback for mainnet assets.
struct CoinGeckoPriceSource: PriceSource {
    static let apiKeyDefaultsKey = "CoinGeckoAPIKey"
    static let defaultBaseURL = URL(string: "https://api.coingecko.com/api/v3")!

    private let baseURL: URL
    private let explicitAPIKey: String?
    private let provider: CoinGeckoProvider

    /// - Parameter apiKey: Overrides the key from Settings or the environment, which is otherwise
    ///   read on every request so a key entered later applies without a relaunch.
    init(
        apiKey: String? = nil,
        baseURL: URL = CoinGeckoPriceSource.defaultBaseURL,
        provider: MoyaProvider<CoinGeckoAPI>? = nil
    ) {
        self.baseURL = baseURL
        explicitAPIKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)

        self.provider = CoinGeckoProvider(provider ?? MoyaProvider(session: Session(
            interceptor: CoinGeckoRateLimitInterceptor.shared
        )))
    }

    var id: String {
        "coinGecko"
    }

    private var apiKey: String? {
        explicitAPIKey ?? Self.configuredAPIKey()
    }

    func usdPrice(_ token: Token, rpcURL: URL) async throws -> Decimal? {
        try await resolvedPrice(token, rpcURL: rpcURL)?.usdPrice
    }

    func resolvedPrice(_ token: Token, rpcURL _: URL) async throws -> CoinGeckoPrice? {
        try await resolvedPrices([token])[0].get()
    }

    /// Prices `tokens` with one request per `maxBatchSize` native assets and per `maxBatchSize`
    /// tokens of a platform, so the call count doesn't grow with the token count. Results align
    /// with `tokens`; `nil` means CoinGecko can't be asked about the token, and ``NoQuote`` that
    /// it was asked and returned no price.
    func resolvedPrices(_ tokens: [Token]) async -> [Result<CoinGeckoPrice?, any Swift.Error>] {
        var results = [Result<CoinGeckoPrice?, any Swift.Error>](repeating: .success(nil), count: tokens.count)

        guard let apiKey, !apiKey.isEmpty else {
            printVerbose("CoinGecko skipped: no API key (defaults '\(Self.apiKeyDefaultsKey)' / env COINGECKO_API_KEY)")
            return results
        }

        // Token indices by CoinGecko id, and by platform then contract address (case-sensitive on some chains).
        var natives: [String: [Int]] = [:]
        var contracts: [String: [String: [Int]]] = [:]

        for (index, token) in tokens.enumerated() {
            switch identifier(for: token) {
            case let .native(coinGeckoId):
                natives[coinGeckoId, default: []].append(index)
            case let .token(platform, address):
                contracts[platform, default: [:]][address, default: []].append(index)
            case nil:
                printVerbose("CoinGecko skipped: no identifier for \(token.symbol) (non-mainnet or unmapped chain)")
            }
        }

        for ids in Self.batches(of: natives.keys.sorted()) {
            printVerbose("CoinGecko request: \(ids.count) native assets")

            let outcome = await fetch {
                try await provider.value.request(.nativePrice(apiKey: apiKey, baseURL: baseURL, coinGeckoIds: ids))
            }

            for id in ids {
                store(outcome, key: id, indices: natives[id] ?? [], coinGeckoId: id, in: &results)
            }
        }

        for (platform, indices) in contracts.sorted(by: { $0.key < $1.key }) {
            for addresses in Self.batches(of: indices.keys.sorted()) {
                printVerbose("CoinGecko request: \(addresses.count) \(platform) tokens")

                let outcome = await fetch {
                    try await provider.value.request(.tokenPrice(
                        addresses: addresses,
                        apiKey: apiKey,
                        baseURL: baseURL,
                        platform: platform
                    ))
                }

                for address in addresses {
                    store(outcome, key: address, indices: indices[address] ?? [], coinGeckoId: nil, in: &results)
                }
            }
        }

        return results
    }
}

extension CoinGeckoPriceSource {
    /// Assets per request, keeping query strings well under URL length limits.
    static let maxBatchSize = 50

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

    static func batches(of keys: [String]) -> [[String]] {
        stride(from: 0, to: keys.count, by: maxBatchSize).map {
            Array(keys[$0..<min($0 + maxBatchSize, keys.count)])
        }
    }

    func fetch(
        _ request: () async throws -> [String: [String: Decimal]]
    ) async -> Result<[String: [String: Decimal]], any Swift.Error> {
        do {
            return try await .success(request())
        } catch {
            return .failure(error)
        }
    }

    func identifier(for token: Token) -> AssetIdentifier? {
        guard let blockchain = token.blockchain, blockchain.isMainnet else {
            return nil
        }

        if token.isNativeToken {
            guard let coinGeckoId = token.coinGeckoId ?? Self.nativeCoinGeckoId(for: blockchain) else {
                return nil
            }

            return .native(coinGeckoId)
        }

        guard let address = token.address, let platform = Self.assetPlatform(for: blockchain) else {
            return nil
        }

        return .token(platform: platform, address: address)
    }

    static func nativeCoinGeckoId(for blockchain: Blockchain) -> String? {
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

    static func assetPlatform(for blockchain: Blockchain) -> String? {
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
            case .robinhood: "robinhood"
            case .unichain: "unichain"
            case .custom: nil
            }

        case .solana: "solana"
        case .sui: "sui"
        case .tron: "tron"
        }
    }

    /// Writes the asset's price (or the request's error) to every token in `indices`.
    func store(
        _ outcome: Result<[String: [String: Decimal]], any Swift.Error>,
        key: String,
        indices: [Int],
        coinGeckoId: String?,
        in results: inout [Result<CoinGeckoPrice?, any Swift.Error>]
    ) {
        let result: Result<CoinGeckoPrice?, any Swift.Error> = outcome.flatMap { response in
            guard let usdPrice = response.first(where: {
                $0.key.caseInsensitiveCompare(key) == .orderedSame
            })?.value["usd"] else {
                return .failure(NoQuote())
            }

            return Result { try resolvedPrice(usdPrice, coinGeckoId: coinGeckoId) }.map { $0 }
        }

        for index in indices {
            results[index] = result
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
    case nativePrice(apiKey: String, baseURL: URL, coinGeckoIds: [String])
    case tokenPrice(addresses: [String], apiKey: String, baseURL: URL, platform: String)
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
        case let .nativePrice(_, _, coinGeckoIds):
            .requestParameters(
                parameters: ["ids": coinGeckoIds.joined(separator: ","), "precision": "full", "vs_currencies": "usd"],
                encoding: URLEncoding.queryString
            )

        case let .tokenPrice(addresses, _, _, _):
            .requestParameters(
                parameters: [
                    "contract_addresses": addresses.joined(separator: ","),
                    "precision": "full",
                    "vs_currencies": "usd"
                ],
                encoding: URLEncoding.queryString
            )
        }
    }

    var validationType: ValidationType {
        .successCodes
    }
}
