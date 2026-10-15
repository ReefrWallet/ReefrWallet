//
//  TronDappProvider+Node.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 13.10.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation
import WalletKit

/// The page's TronWeb talks to the node through native: its HTTP
/// provider is replaced with one that calls `nodeRequest`. That keeps
/// the TronGrid API key out of the page, sidesteps the page's CSP, and
/// shares the app's rate limiting. Only read/build/broadcast node APIs
/// are forwarded; nothing here involves the wallet's keys.
extension TronDappProvider {
    func nodeRequest(params: JSONValue, context: DappRequestContext) async throws(DappError) -> JSONValue {
        let request = try Self.nodeRequestTarget(params)
        let account = await context.session.selectedAccount(.tron)

        let data: Data
        do {
            let client = if let account {
                try clientProvider.tronClient(for: account)
            } else {
                try clientProvider.tronClient(blockchain: .tron(.mainnet))
            }

            data = try await client.relay(path: request.path, query: request.query, body: request.body)
        } catch {
            throw .internalError("\(error)")
        }

        do {
            return try JSONValue(data: data)
        } catch {
            throw .internalError("the Tron node returned a non-JSON response")
        }
    }

    struct NodeRequestTarget: Equatable {
        let path: String
        let query: [URLQueryItem]
        let body: Data?
    }

    /// Validates `{path, method, payload}`: `wallet/*`/`walletsolidity/*`
    /// (GET or POST) or `v1/*` event/account reads (GET only).
    static func nodeRequestTarget(_ params: JSONValue) throws(DappError) -> NodeRequestTarget {
        guard
            let rawPath = params["path"]?.stringValue,
            let method = params["method"]?.stringValue?.lowercased()
        else {
            throw .invalidParams("nodeRequest expects {path, method}")
        }

        let path = String(rawPath.drop { $0 == "/" })
        let payload = params["payload"]?.objectValue ?? [:]

        let isWalletAPI = path.wholeMatch(of: /(wallet|walletsolidity)\/[A-Za-z0-9]+/) != nil
        let isEventAPI = path.wholeMatch(of: /v1\/[A-Za-z0-9_\-\/]+/) != nil

        switch method {
        case "get" where isWalletAPI || isEventAPI:
            var query: [URLQueryItem] = []
            for (key, value) in payload.sorted(by: { $0.key < $1.key }) {
                query.append(URLQueryItem(name: key, value: try queryValue(value)))
            }

            return NodeRequestTarget(path: path, query: query, body: nil)
        case "post" where isWalletAPI:
            guard let body = try? JSONValue.object(payload).encoded() else {
                throw .invalidParams("unable to encode the request body")
            }

            return NodeRequestTarget(path: path, query: [], body: body)
        default:
            throw .invalidParams("unsupported Tron node request: \(method.uppercased()) /\(path)")
        }
    }

    private static func queryValue(_ value: JSONValue) throws(DappError) -> String {
        switch value {
        case let .bool(bool):
            return bool ? "true" : "false"
        case let .number(number):
            return number.truncatingRemainder(dividingBy: 1) == 0 && abs(number) < 1e15
                ? String(Int64(number))
                : String(number)
        case let .string(string):
            return string
        case .array, .null, .object:
            throw .invalidParams("unsupported query parameter")
        }
    }
}
