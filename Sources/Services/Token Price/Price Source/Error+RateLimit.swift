import Alamofire
import Foundation
import Moya
import WalletKit

extension Error {
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
