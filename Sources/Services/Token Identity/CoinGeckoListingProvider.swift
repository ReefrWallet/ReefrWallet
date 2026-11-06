import Foundation
import WalletKit

/// CoinGecko's `/coins/list?include_platform=true`: every coin with its contract address per platform.
/// Works without an API key; the Settings key is sent when set.
struct CoinGeckoListingProvider: TokenListingProvider {
    /// The asset platforms `CoinGeckoPriceSource.assetPlatform(for:)` maps to; others are dropped on download.
    static let supportedPlatforms: Set<String> = [
        "aptos", "arbitrum-one", "avalanche", "base", "binance-smart-chain", "cardano", "ethereum", "hyperevm",
        "mantle", "monad", "optimistic-ethereum", "polygon-pos", "robinhood", "solana", "sui", "tron", "unichain"
    ]

    let apiKey: @Sendable () -> String?
    let baseURL: URL
    let session: URLSession

    init(
        apiKey: @escaping @Sendable () -> String? = { CoinGeckoPriceSource.configuredAPIKey() },
        baseURL: URL = CoinGeckoPriceSource.defaultBaseURL,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.session = session
    }

    var id: String {
        "coinGecko"
    }

    /// The list held about 22,800 coins in November 2026.
    var minimumEntryCount: Int {
        10_000
    }

    func fetchEntries() async throws -> [TokenListingEntry] {
        var components = URLComponents(
            url: baseURL.appending(path: "coins/list"),
            resolvingAgainstBaseURL: false
        )

        components?.queryItems = [URLQueryItem(name: "include_platform", value: "true")]

        guard let url = components?.url else {
            throw ReefrError.invalidData
        }

        var request = URLRequest(url: url)

        if let key = apiKey()?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            request.setValue(key, forHTTPHeaderField: "x-cg-demo-api-key")
        }

        let (data, response) = try await session.data(for: request)

        guard let status = (response as? HTTPURLResponse)?.statusCode else {
            throw BlockchainClientError.invalidResponse(reason: "no HTTP response")
        }

        guard (200..<300).contains(status) else {
            throw BlockchainClientError.invalidResponse(reason: "HTTP status \(status)")
        }

        // Plain decoder: the app's `decoded()` converts snake case, which would rewrite platform ids.
        let coins = try JSONDecoder().decode([Coin].self, from: data)

        return coins.flatMap { coin in
            coin.platforms.compactMap { platform, address -> TokenListingEntry? in
                guard Self.supportedPlatforms.contains(platform), let address, !address.isEmpty else {
                    return nil
                }

                return TokenListingEntry(address: address, externalId: coin.id, platform: platform)
            }
        }
    }

    func platform(for blockchain: Blockchain) -> String? {
        CoinGeckoPriceSource.assetPlatform(for: blockchain)
    }
}

private extension CoinGeckoListingProvider {
    struct Coin: Decodable {
        let id: String
        let platforms: [String: String?]

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            platforms = try container.decodeIfPresent([String: String?].self, forKey: .platforms) ?? [:]
        }

        private enum CodingKeys: String, CodingKey {
            case id
            case platforms
        }
    }
}
