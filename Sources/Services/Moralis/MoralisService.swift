//
//  MoralisService.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 21.12.25.
//  Copyright © 2025 Reefr Wallet. All rights reserved.
//

import Foundation
import Moya

enum MoralisAPI {
    // case getMetadata(chain: String, tokens: [String], apiKey: String)
    case listBalances(address: String, chain: String, tokens: [String]?, pageCursor: String?, apiKey: String)
}

struct MoralisService {
    let apiKey: String

    private let provider: MoyaProvider<MoralisAPI>

    init(apiKey: String, proxyHost: String? = nil, proxyPort: Int? = nil) {
        let configuration: URLSessionConfiguration = if let proxyHost {
            .withProxy(proxyHost, port: proxyPort ?? 9090)
        } else {
            .default
        }

        let session = Session(configuration: configuration)
        self.provider = .init(session: session)
        self.apiKey = apiKey
    }

    func listERC20Balances(
        account: Account,
        tokens: [Token]?,
        pageCursor: String?
    ) async throws -> MoralisPageResponse<MoralisBalance> {
        guard case let .ethereum(chainId) = account.blockchainConfig.blockchain else {
            throw Error.invalidData
        }

        let target = MoralisAPI.listBalances(
            address: account.address,
            chain: makeChain(chainId),
            tokens: tokens?.compactMap(\.address),
            pageCursor: pageCursor,
            apiKey: apiKey
        )

        return try await provider.request(target)
    }

    func makeChain(_ chain: UInt64) -> String {
        let str = "0x" + String(chain, radix: 16)
        return str
    }
}

extension MoralisAPI: TargetType {
    var path: String {
        switch self {
        /* case .getMetadata:
            "/api/v2.2/erc20/metadata" */
        case let .listBalances(owner, _, _, _, _):
            "/api/v2.2/wallets/\(owner)/tokens"
        }
    }

    var method: Moya.Method {
        .get
    }

    var task: Task {
        switch self {
        /*case let .getMetadata(chain, addresses, _):
            let parameters: [String: Any] = ["chain": chain, "addresses": addresses]
            return .requestParameters(parameters: parameters, encoding: URLEncoding.queryString)*/
        case let .listBalances(_, chain, tokens, pageCursor, _):
            var parameters: [String: Any] = ["chain": chain, "limit": 100]

            if let tokens, !tokens.isEmpty {
                parameters["token_addresses"] = tokens
            }

            if let pageCursor {
                parameters["cursor"] = pageCursor
            }

            return .requestParameters(parameters: parameters, encoding: URLEncoding.queryString)
        }
    }

    var baseURL: URL {
        URL(string: "https://deep-index.moralis.io")!
    }

    var headers: [String: String]? {
        switch self {
        /* case let .getMetadata(_, _, apiKey):
            ["X-API-Key": apiKey] */
        case let .listBalances(_, _, _, _, apiKey):
            ["X-API-Key": apiKey]
        }
    }
}
