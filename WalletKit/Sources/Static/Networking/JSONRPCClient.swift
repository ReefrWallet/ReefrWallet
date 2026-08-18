//
//  JSONRPCClient.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 17/08/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation

/// A JSON-RPC 2.0 transport over HTTPS POST — the `{jsonrpc, id, method,
/// params}` → `{result}`/`{error}` envelope Ethereum's execution-apis use.
struct JSONRPCClient {
    let endpoint: URL
    var session: URLSession = .shared

    private struct Envelope<Params: Encodable>: Encodable {
        let jsonrpc = "2.0"
        let id = 1
        let method: String
        let params: Params
    }

    private struct ErrorPayload: Decodable {
        let code: Int
        let message: String
    }

    private struct ResponseEnvelope<Result: Decodable>: Decodable {
        let result: Result?
        let error: ErrorPayload?
    }

    /// Calls `method` with `params`, decoding the JSON-RPC `result` as
    /// `Result`.
    ///
    /// - Throws: ``BlockchainClientError`` for a transport failure, a
    ///   non-2xx HTTP status, a JSON-RPC `error` response, or a `result`
    ///   that doesn't decode as `Result`.
    func call<Params: Encodable, Result: Decodable>(
        method: String,
        params: Params
    ) async throws -> Result {
        var request = URLRequest(url: endpoint)

        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Envelope(method: method, params: params))

        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw BlockchainClientError.transportError(reason: error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw BlockchainClientError.invalidResponse(reason: "unexpected HTTP status \(status)")
        }

        let envelope: ResponseEnvelope<Result>

        do {
            envelope = try JSONDecoder().decode(ResponseEnvelope<Result>.self, from: data)
        } catch {
            throw BlockchainClientError.decodingFailed(reason: error.localizedDescription)
        }

        if let error = envelope.error {
            throw BlockchainClientError.rpcError(code: error.code, message: error.message)
        }

        guard let result = envelope.result else {
            throw BlockchainClientError.invalidResponse(reason: "response had neither result nor error")
        }

        return result
    }
}
