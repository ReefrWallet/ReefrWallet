import WalletKit

/// A source of one asset's current USD price.
protocol PriceSource: Sendable {
    /// Returns `nil` when this source does not support `token`.
    func usdPrice(_ token: Token, rpcURL: URL) async throws -> Decimal?
}
