import Foundation
import WalletKit

extension Error {
    /// Whether a source failed because it can't serve the token (not listed, a reverting contract
    /// call, an empty result), not because of a transient fault. Rate limits never count.
    var isSourceUnavailable: Bool {
        guard !isRateLimited else {
            return false
        }

        switch self as any Error {
        case is TokenNotListed:
            return true
        case let BlockchainClientError.rpcError(_, message):
            return message.localizedCaseInsensitiveContains("revert")
        case let BlockchainClientError.decodingFailed(reason):
            return reason.hasPrefix("empty")
        default:
            return false
        }
    }

    /// Whether a price source failed because its provider is rate-limiting this app.
    var isRateLimited: Bool {
        isQuotaExceeded
    }
}
