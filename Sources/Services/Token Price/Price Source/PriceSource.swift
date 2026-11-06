import WalletKit

/// A source of one asset's current USD price.
protocol PriceSource: Sendable {
    /// Stable identifier, persisted with the prices this source quotes.
    var id: String { get }

    /// Returns `nil` when this source declines `token` without asking anyone; throws
    /// ``TokenNotListed`` when it asked and the token isn't there, and ``NoQuote`` when it asked
    /// and has no price for it right now.
    func usdPrice(_ token: Token, rpcURL: URL) async throws -> Decimal?
}

/// A source asked and the token isn't there; sources skip such tokens for a week.
struct TokenNotListed: LocalizedError {
    var errorDescription: String? {
        "Token is not listed"
    }
}

/// A source answered but has no price for the token right now; recorded, but retried normally.
struct NoQuote: LocalizedError {
    var errorDescription: String? {
        "Source has no quote for the token"
    }
}
