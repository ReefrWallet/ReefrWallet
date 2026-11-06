import WalletKit

/// A source that confirms a token contract is a real asset, so it gets priced and counts in balances.
protocol TokenIdentitySource: Sendable {
    /// Changes when the source's local data changes, so earlier negative answers get rechecked.
    var configurationVersion: String { get }
    var id: String { get }

    /// Aligned with `tokens`. `nil` means the source declined without asking anyone;
    /// ``TokenNotListed`` means it asked and the token isn't there.
    func identities(of tokens: [Token]) async -> [Result<TokenIdentity?, any Swift.Error>]
}

struct TokenIdentity: Sendable {
    /// The source's own id for the token, e.g. a CoinGecko coin id.
    let externalId: String?
}

/// A source of optional token details. Never decides whether a token is real.
protocol TokenMetadataSource: Sendable {
    var id: String { get }

    /// Aligned with `tokens`. `nil` means the source declined without asking anyone.
    func metadata(for tokens: [Token]) async -> [Result<TokenMetadata?, any Swift.Error>]
}

struct TokenMetadata: Sendable {
    let imageURL: URL?
}

/// Backs off after rate limiting: 30 s, doubling to 10 min, reset by a success.
struct RateLimitBackoff: Sendable {
    static let maxDelay: TimeInterval = 10 * 60
    static let minDelay: TimeInterval = 30

    private(set) var delay: TimeInterval?
    private(set) var resumesAt: Date?

    func isPaused(at now: Date) -> Bool {
        resumesAt.map { now < $0 } ?? false
    }

    mutating func recordRateLimit(at now: Date) {
        let next = delay.map { min($0 * 2, Self.maxDelay) } ?? Self.minDelay
        delay = next
        resumesAt = now.addingTimeInterval(next)
    }

    mutating func recordSuccess() {
        delay = nil
        resumesAt = nil
    }
}
