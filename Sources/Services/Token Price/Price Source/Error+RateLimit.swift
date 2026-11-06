import Alamofire
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
        switch self as any Error {
        case let error as AFError:
            error.responseCode == 429

        case let BlockchainClientError.invalidResponse(reason):
            reason.contains("HTTP status 429") || reason.hasPrefix("HTTP 429")

        case let BlockchainClientError.rpcError(code, _):
            // -32005: the de facto JSON-RPC "limit exceeded" code.
            code == 429 || code == -32005

        case let MoyaError.underlying(error, response):
            response?.statusCode == 429 || error.isRateLimited

        case let error as MoyaError:
            error.response?.statusCode == 429

        default:
            false
        }
    }
}
