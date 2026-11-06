import Foundation
import WalletKit

/// Token images from CoinGecko's `/coins/markets`, up to 250 coins per request. Needs an API key:
/// the keyless quota is too thin for it, so without one it declines.
struct CoinGeckoMetadataSource: TokenMetadataSource {
    private static let batchSize = 250

    let apiKey: @Sendable () -> String?
    let baseURL: URL
    /// Resolves CoinGecko ids by contract address for tokens identified without one, e.g. by a feed table.
    let listing: CachedTokenListing?
    let session: URLSession

    init(
        apiKey: @escaping @Sendable () -> String? = { CoinGeckoPriceSource.configuredAPIKey() },
        baseURL: URL = CoinGeckoPriceSource.defaultBaseURL,
        listing: CachedTokenListing? = nil,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.listing = listing
        self.session = session
    }

    var id: String {
        "coinGecko"
    }

    func metadata(for tokens: [Token]) async -> [Result<TokenMetadata?, any Swift.Error>] {
        var results = [Result<TokenMetadata?, any Swift.Error>](repeating: .success(nil), count: tokens.count)

        guard let key = apiKey()?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            return results
        }

        var indices: [String: [Int]] = [:]
        let access = await listingAccess(for: tokens)

        for (index, token) in tokens.enumerated() {
            if let coinGeckoId = token.coinGeckoId ?? Self.listedId(of: token, in: access) {
                indices[coinGeckoId, default: []].append(index)
            } else if token.coinGeckoId == nil, let access {
                results[index] = .failure(Self.missingIdError(access))
            }
        }

        let ids = indices.keys.sorted()

        for start in stride(from: 0, to: ids.count, by: Self.batchSize) {
            let batch = Array(ids[start..<min(start + Self.batchSize, ids.count)])

            do {
                let images = try await fetchImages(ids: batch, key: key)

                for id in batch {
                    let result: Result<TokenMetadata?, any Swift.Error> =
                        images[id].map { .success(TokenMetadata(imageURL: $0)) } ?? .failure(TokenNotListed())

                    for index in indices[id] ?? [] {
                        results[index] = result
                    }
                }
            } catch {
                for id in batch {
                    for index in indices[id] ?? [] {
                        results[index] = .failure(error)
                    }
                }
            }
        }

        return results
    }

    /// The listing, only when some token lacks a CoinGecko id.
    private func listingAccess(for tokens: [Token]) async -> TokenListingAccess? {
        guard let listing, tokens.contains(where: { $0.coinGeckoId == nil }) else {
            return nil
        }

        return await listing.access()
    }

    private static func listedId(of token: Token, in access: TokenListingAccess?) -> String? {
        guard let blockchain = token.blockchain,
              let address = token.address,
              let platform = CoinGeckoPriceSource.assetPlatform(for: blockchain)
        else {
            return nil
        }

        return access?.listing?.externalId(platform: platform, address: address)
    }

    /// Absent from a fresh listing the token has no CoinGecko page; otherwise nothing is known yet.
    private static func missingIdError(_ access: TokenListingAccess) -> any Swift.Error {
        access.isFresh ? TokenNotListed() : access.error ?? ListingIdentitySource.ListingUnavailable()
    }

    private func fetchImages(ids: [String], key: String) async throws -> [String: URL] {
        var components = URLComponents(
            url: baseURL.appending(path: "coins/markets"),
            resolvingAgainstBaseURL: false
        )

        components?.queryItems = [
            URLQueryItem(name: "ids", value: ids.joined(separator: ",")),
            URLQueryItem(name: "per_page", value: String(Self.batchSize)),
            URLQueryItem(name: "vs_currency", value: "usd")
        ]

        guard let url = components?.url else {
            throw ReefrError.invalidData
        }

        var request = URLRequest(url: url)
        request.setValue(key, forHTTPHeaderField: "x-cg-demo-api-key")

        let (data, response) = try await session.data(for: request)

        guard let status = (response as? HTTPURLResponse)?.statusCode else {
            throw BlockchainClientError.invalidResponse(reason: "no HTTP response")
        }

        guard (200..<300).contains(status) else {
            throw BlockchainClientError.invalidResponse(reason: "HTTP status \(status)")
        }

        let coins = try JSONDecoder().decode([Coin].self, from: data)

        return Dictionary(
            coins.compactMap { coin in coin.image.flatMap(URL.init(string:)).map { (coin.id, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private struct Coin: Decodable {
        let id: String
        let image: String?
    }
}
