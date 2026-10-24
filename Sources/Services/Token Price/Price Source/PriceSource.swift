import WalletKit

/// A source of one asset's current USD price.
protocol PriceSource: Sendable {
    /// Stable identifier, persisted with the prices this source quotes.
    var id: String { get }

    /// Returns `nil` when this source does not support `token`.
    func usdPrice(_ token: Token, rpcURL: URL) async throws -> Decimal?
}
