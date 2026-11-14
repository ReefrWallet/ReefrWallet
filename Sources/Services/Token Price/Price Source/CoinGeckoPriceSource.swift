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
                contracts[platform, default: [:]][Self.requestAddress(address, platform: platform), default: []]
                    .append(index)
            case nil:
                printVerbose("CoinGecko skipped: no identifier for \(token.symbol) (non-mainnet or unmapped chain)")
            }
        }

        // A failure of the whole provider (a rate limit, an outage) ends the pass: assets not yet asked about get it
        // without another request.
        var halt: PriceOutcome?

        await priceNatives(natives, apiKey: apiKey, halt: &halt, in: &results)

        for (platform, indices) in contracts.sorted(by: { $0.key < $1.key }) {
            let batches = Self.batches(of: indices.keys.sorted())
            printVerbose("CoinGecko request: \(indices.count) \(platform) tokens")

            let outcomes = await Self.tokenOutcomes(forBatches: batches, platform: platform, halt: &halt) { asked in
                await fetch {
                    try await provider.value.request(.tokenPrice(
                        addresses: asked,
                        apiKey: apiKey,
                        baseURL: baseURL,
                        platform: platform
                    ))
                }
            }

            for (address, outcome) in outcomes {
                let at = indices[address] ?? []
                store(outcome, key: address, indices: at, coinGeckoId: nil, platform: platform, in: &results)
            }
        }

        return results
    }
}

extension CoinGeckoPriceSource {
    /// Prices the native assets, a batch per request, unless `halt` is set.
    func priceNatives(
        _ natives: [String: [Int]],
        apiKey: String,
        halt: inout PriceOutcome?,
        in results: inout [Result<CoinGeckoPrice?, any Swift.Error>]
    ) async {
        for ids in Self.batches(of: natives.keys.sorted()) {
            printVerbose("CoinGecko request: \(ids.count) native assets")

            let outcome: PriceOutcome

            if let halted = halt {
                outcome = halted
            } else {
                outcome = await fetch {
                    try await provider.value.request(.nativePrice(apiKey: apiKey, baseURL: baseURL, coinGeckoIds: ids))
                }

                halt = Self.halting(outcome)
            }

            for id in ids {
                store(outcome, key: id, indices: natives[id] ?? [], coinGeckoId: id, in: &results)
            }
        }
    }

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
        case .ton: "the-open-network"
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
        case .ton: "the-open-network"
        case .tron: "tron"
        }
    }

    /// Writes the asset's price (or the request's error) to every token in `indices`.
    func store(
        _ outcome: Result<[String: [String: Decimal]], any Swift.Error>,
        key: String,
        indices: [Int],
        coinGeckoId: String?,
        platform: String? = nil,
        in results: inout [Result<CoinGeckoPrice?, any Swift.Error>]
    ) {
        let result: Result<CoinGeckoPrice?, any Swift.Error> = outcome.flatMap { response in
            guard let usdPrice = response.first(where: {
                Self.isSameContract($0.key, key, platform: platform)
            })?.value["usd"] else {
                return .failure(NoQuote())
            }

            return Result { try resolvedPrice(usdPrice, coinGeckoId: coinGeckoId) }.map { $0 }
        }

        for index in indices {
            results[index] = result
        }
    }

    typealias PriceOutcome = Result<[String: [String: Decimal]], any Swift.Error>

    /// `outcome` when it is a failure of the whole provider, which no further request would survive.
    static func halting(_ outcome: PriceOutcome) -> PriceOutcome? {
        if case let .failure(error) = outcome, error.isProviderWide {
            return outcome
        }

        return nil
    }

    /// The outcome per address of asking for `batches` in turn. Once `halt` is set, by this pass or an earlier one,
    /// no request is made and the rest carry it.
    static func tokenOutcomes(
        forBatches batches: [[String]],
        platform: String,
        halt: inout PriceOutcome?,
        request: ([String]) async -> PriceOutcome
    ) async -> [(String, PriceOutcome)] {
        var all: [(String, PriceOutcome)] = []

        for addresses in batches {
            if let halted = halt {
                all += addresses.map { ($0, halted) }
                continue
            }

            let outcomes = await tokenOutcomes(addresses, platform: platform, request: request)
            halt = outcomes.lazy.compactMap { halting($0.1) }.first
            all += outcomes
        }

        return all
    }

    /// The outcome per address of asking for `addresses`. A TON batch that CoinGecko rejects for its size (a plan may
    /// accept one contract per request) is asked again one master at a time; any other failure, an authentication
    /// error or an outage included, is not retried per master. Retrying stops at the first failure of the whole
    /// provider.
    static func tokenOutcomes(
        _ addresses: [String],
        platform: String,
        request: ([String]) async -> PriceOutcome
    ) async -> [(String, PriceOutcome)] {
        let batch = await request(addresses)

        guard platform == "the-open-network", addresses.count > 1, case let .failure(error) = batch,
              error.isBatchSizeRejection
        else {
            return addresses.map { ($0, batch) }
        }

        var singles: [(String, PriceOutcome)] = []
        var stopped: PriceOutcome?

        for address in addresses {
            if let stopped {
                singles.append((address, stopped))
                continue
            }

            let outcome = await request([address])
            singles.append((address, outcome))
            stopped = halting(outcome)
        }

        return singles
    }

    /// What to ask CoinGecko for. One TON master has several encodings, so aliases collapse into the form CoinGecko
    /// lists (mainnet, bounceable); other platforms are asked as given.
    static func requestAddress(_ address: String, platform: String) -> String {
        guard platform == "the-open-network", let parsed = try? TonAddress(string: address) else {
            return address
        }

        let canonical = try? TonAddress(workchain: parsed.workchain, hash: parsed.hash, isBounceable: true)
        return canonical?.string ?? address
    }

    /// Whether `response` names the contract that was asked for: by parsed identity on TON, where friendly
    /// addresses are case-sensitive and may come back in another encoding, else ignoring case.
    static func isSameContract(_ response: String, _ asked: String, platform: String?) -> Bool {
        guard platform == "the-open-network" else {
            return response.caseInsensitiveCompare(asked) == .orderedSame
        }

        guard let lhs = TokenAddress.tonIdentity(response), let rhs = TokenAddress.tonIdentity(asked) else {
            return response == asked
        }

        return lhs == rhs
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
