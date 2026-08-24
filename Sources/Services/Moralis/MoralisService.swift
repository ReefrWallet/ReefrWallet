//
//  MoralisService.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 21.12.25.
//  Copyright © 2025 Reefr Wallet. All rights reserved.
//

import Foundation
import Moya
import SwiftUI

enum MoralisAPI {
    case listBalances(address: String, chain: String, tokens: [String]?, pageCursor: String?, apiKey: String)
}

struct MoralisService {
    private let apiKey: String
    private let provider: MoyaProvider<MoralisAPI>

    init(apiKey: String, proxyHost: String? = nil, proxyPort: Int? = nil) {
        let configuration: URLSessionConfiguration = if let proxyHost {
            .withProxy(proxyHost, port: proxyPort ?? 9090)
        } else {
            .default
        }
        self.provider = .init(session: Session(configuration: configuration))
        self.apiKey = apiKey
    }

    func listERC20Balances(
        account: Account,
        tokens: [Token]?,
        pageCursor: String?
    ) async throws -> MoralisPageResponse<MoralisBalance> {
        guard case let .evm(network) = account.blockchain else {
            throw Error.invalidData
        }

        return try await provider.request(
            .listBalances(
                address: account.address,
                chain: makeChain(network.chainId),
                tokens: tokens?.compactMap(\.address),
                pageCursor: pageCursor,
                apiKey: apiKey
            )
        )
    }

    private func makeChain(_ chain: UInt64) -> String {
        "0x" + String(chain, radix: 16)
    }
}

extension MoralisAPI: TargetType {
    var path: String {
        switch self {
        case let .listBalances(owner, _, _, _, _):
            "/api/v2.2/wallets/\(owner)/tokens"
        }
    }

    var method: Moya.Method { .get }

    var task: Task {
        switch self {
        case let .listBalances(_, chain, tokens, pageCursor, _):
            var parameters: [String: Any] = ["chain": chain, "limit": 100]
            if let tokens, !tokens.isEmpty { parameters["token_addresses"] = tokens }
            if let pageCursor { parameters["cursor"] = pageCursor }
            return .requestParameters(parameters: parameters, encoding: URLEncoding.queryString)
        }
    }

    var baseURL: URL { URL(string: "https://deep-index.moralis.io")! }

    var headers: [String: String]? {
        switch self {
        case let .listBalances(_, _, _, _, apiKey):
            ["X-API-Key": apiKey]
        }
    }
}
