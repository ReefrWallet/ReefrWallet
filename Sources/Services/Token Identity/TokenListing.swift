import Foundation
import WalletKit

/// One token a provider lists on one of its platforms.
struct TokenListingEntry: Codable, Sendable {
    let address: String
    let externalId: String
    let platform: String
}

/// A provider's complete token listing, e.g. CoinGecko's coin list with platforms.
protocol TokenListingProvider: Sendable {
    var id: String { get }
    /// Fewest entries a plausible response has; guards against truncation, doesn't prove completeness.
    var minimumEntryCount: Int { get }

    /// Every entry the provider lists on platforms this app can use; pages internally if needed.
    func fetchEntries() async throws -> [TokenListingEntry]
    /// The provider's platform id for `blockchain`; `nil` when it doesn't cover the chain.
    func platform(for blockchain: Blockchain) -> String?
}

/// A downloaded listing indexed by platform and normalized address.
struct TokenListing: Codable, Sendable {
    let entries: [String: [String: String]]
    let fetchedAt: Date

    init(entries: [TokenListingEntry], fetchedAt: Date) {
        var index: [String: [String: String]] = [:]

        for entry in entries where !entry.address.isEmpty {
            let address = TokenAddress.normalized(entry.address, platform: entry.platform)
            index[entry.platform, default: [:]][address] = entry.externalId
        }

        self.entries = index
        self.fetchedAt = fetchedAt
    }

    func externalId(platform: String, address: String) -> String? {
        entries[platform]?[TokenAddress.normalized(address, platform: platform)]
    }
}

/// Address forms that name the same contract.
enum TokenAddress {
    /// EVM addresses are case-insensitive, Move coin types compare in canonical form, and base58
    /// addresses (Solana, Tron) and Cardano asset ids are compared exactly.
    static func normalized(_ address: String, platform: String) -> String {
        switch platform {
        case "sui", "aptos":
            (try? MoveTypeTag.canonicalCoinType(address)) ?? address.lowercased()
        case "solana", "tron", "cardano":
            address
        default:
            address.lowercased()
        }
    }
}

/// What ``CachedTokenListing`` could offer a caller.
struct TokenListingAccess: Sendable {
    /// Why the listing couldn't be refreshed, if it couldn't.
    let error: (any Swift.Error)?
    /// Whether the listing was fetched within ``CachedTokenListing/maxAge``.
    let isFresh: Bool
    let listing: TokenListing?
}

/// Keeps one provider's listing in memory and in the Caches directory, refreshing it at most once
/// a day and backing off on its own when the provider rate-limits.
actor CachedTokenListing {
    static let maxAge: TimeInterval = 24 * 60 * 60

    private let cacheURL: URL?
    private let now: @Sendable () -> Date
    private let provider: any TokenListingProvider
    private var backoff = RateLimitBackoff()
    private var hasLoadedCache = false
    private var lastError: (any Swift.Error)?
    private var listing: TokenListing?

    /// - Parameter cacheURL: Where the listing is kept between launches; `nil` keeps it in memory only.
    init(
        provider: any TokenListingProvider,
        cacheURL: URL? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.cacheURL = cacheURL
        self.now = now
        self.provider = provider
    }

    func access() async -> TokenListingAccess {
        loadCacheIfNeeded()
        let current = now()

        if let listing, current.timeIntervalSince(listing.fetchedAt) < Self.maxAge {
            return TokenListingAccess(error: nil, isFresh: true, listing: listing)
        }

        guard !backoff.isPaused(at: current) else {
            return TokenListingAccess(error: lastError ?? RateLimited(), isFresh: false, listing: listing)
        }

        do {
            let entries = try await provider.fetchEntries()

            guard entries.count >= provider.minimumEntryCount else {
                throw BlockchainClientError.decodingFailed(
                    reason: "\(provider.id) listing has only \(entries.count) entries"
                )
            }

            let fresh = TokenListing(entries: entries, fetchedAt: now())
            listing = fresh
            lastError = nil
            backoff.recordSuccess()
            save(fresh)
            return TokenListingAccess(error: nil, isFresh: true, listing: fresh)
        } catch {
            printWarning("\(provider.id) listing refresh failed: \(error)")
            lastError = error

            if error.isRateLimited {
                backoff.recordRateLimit(at: current)
            }

            return TokenListingAccess(error: error, isFresh: false, listing: listing)
        }
    }

    private func loadCacheIfNeeded() {
        guard !hasLoadedCache else {
            return
        }

        hasLoadedCache = true

        guard let cacheURL, let data = try? Data(contentsOf: cacheURL) else {
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        listing = try? decoder.decode(TokenListing.self, from: data)
    }

    private func save(_ listing: TokenListing) {
        guard let cacheURL else {
            return
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970

        do {
            let directory = cacheURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encoder.encode(listing).write(to: cacheURL, options: .atomic)
        } catch {
            printWarning("Cannot cache \(provider.id) listing: \(error)")
        }
    }

    /// Returned while backing off before any request was made.
    private struct RateLimited: LocalizedError {
        var errorDescription: String? {
            "Listing refresh is paused after rate limiting"
        }
    }
}

/// Identifies tokens a provider's listing contains. A token absent from a fresh listing isn't
/// listed; absent from a stale one, nothing is known.
struct ListingIdentitySource: TokenIdentitySource {
    let listing: CachedTokenListing
    let provider: any TokenListingProvider

    var configurationVersion: String {
        "listing-1"
    }

    var id: String {
        provider.id
    }

    func identities(of tokens: [Token]) async -> [Result<TokenIdentity?, any Swift.Error>] {
        let platforms = tokens.map { token in
            token.blockchain.flatMap { $0.isMainnet ? provider.platform(for: $0) : nil }
        }

        guard zip(tokens, platforms).contains(where: { $0.address != nil && $1 != nil }) else {
            return tokens.map { _ in .success(nil) }
        }

        let access = await listing.access()

        return zip(tokens, platforms).map { token, platform in
            guard let address = token.address, let platform else {
                return .success(nil)
            }

            if let externalId = access.listing?.externalId(platform: platform, address: address) {
                return .success(TokenIdentity(externalId: externalId))
            }

            if access.isFresh {
                return .failure(TokenNotListed())
            }

            return .failure(access.error ?? ListingUnavailable())
        }
    }

    /// No listing has been downloaded yet.
    struct ListingUnavailable: LocalizedError {
        var errorDescription: String? {
            "Token listing is not available yet"
        }
    }
}
