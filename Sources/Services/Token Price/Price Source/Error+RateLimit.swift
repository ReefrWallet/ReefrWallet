import Foundation
import Moya
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

    /// Whether the provider as a whole is failing, so asking about other assets would fail too: rate limiting, or
    /// a server error, from a node or an HTTP API (the retry policy has already given up on it by now).
    var isProviderWide: Bool {
        if isRateLimited {
            return true
        }

        if case .serverError? = self as? BlockchainClientError {
            return true
        }

        return ((self as? MoyaError)?.response?.statusCode ?? 0) >= 500
    }

    /// Whether CoinGecko rejected a request for asking about more contracts than the plan allows: HTTP 400 with
    /// its error code 10012, at the top level or under `status`.
    var isBatchSizeRejection: Bool {
        guard let response = (self as? MoyaError)?.response, response.statusCode == 400,
              let body = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any]
        else {
            return false
        }

        let status = body["status"] as? [String: Any]
        return (body["error_code"] as? Int) == 10_012 || (status?["error_code"] as? Int) == 10_012
    }
}
