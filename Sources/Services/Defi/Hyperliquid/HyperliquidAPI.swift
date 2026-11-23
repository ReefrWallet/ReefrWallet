//
//  HyperliquidAPI.swift
//  Reefr Wallet
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation
@preconcurrency import Moya
import WalletKit

/// The HyperCore network behind a HyperEVM account. See ADR-074.
enum HyperliquidNetwork: String, Codable, Sendable {
    case mainnet
    case testnet

    var origin: String {
        switch self {
        case .mainnet: "https://api.hyperliquid.xyz"
        case .testnet: "https://api.hyperliquid-testnet.xyz"
        }
    }
}

/// One `POST /info` query.
enum HyperliquidRequest: Hashable, Sendable {
    case allPerpMetas
    case borrowLendUserState(user: String)
    case clearinghouseState(user: String, dex: String)
    case delegatorSummary(user: String)
    case perpDexs
    case spotClearinghouseState(user: String)
    case spotMetaAndAssetCtxs
    case userAbstraction(user: String)
    case userVaultEquities(user: String)

    /// The request body: `type` plus `user`/`dex` where needed.
    var body: [String: String] {
        switch self {
        case .allPerpMetas, .perpDexs, .spotMetaAndAssetCtxs:
            ["type": type]
        case let .borrowLendUserState(user), let .delegatorSummary(user), let .spotClearinghouseState(user),
             let .userAbstraction(user), let .userVaultEquities(user):
            ["type": type, "user": user]
        case let .clearinghouseState(user, dex):
            ["dex": dex, "type": type, "user": user]
        }
    }

    var type: String {
        switch self {
        case .allPerpMetas: "allPerpMetas"
        case .borrowLendUserState: "borrowLendUserState"
        case .clearinghouseState: "clearinghouseState"
        case .delegatorSummary: "delegatorSummary"
        case .perpDexs: "perpDexs"
        case .spotClearinghouseState: "spotClearinghouseState"
        case .spotMetaAndAssetCtxs: "spotMetaAndAssetCtxs"
        case .userAbstraction: "userAbstraction"
        case .userVaultEquities: "userVaultEquities"
        }
    }

    /// The documented REST weight of an info request of `type`.
    static func weight(type: String?) -> Int {
        switch type {
        case "allMids", "clearinghouseState", "exchangeStatus", "l2Book", "orderStatus", "spotClearinghouseState": 2
        case "userRole": 60
        default: 20
        }
    }
}

struct HyperliquidTarget: TargetType {
    let network: HyperliquidNetwork
    let request: HyperliquidRequest

    var baseURL: URL {
        URL(string: network.origin)!
    }

    var headers: [String: String]? {
        ["Content-Type": "application/json"]
    }

    var method: Moya.Method {
        .post
    }

    var path: String {
        "info"
    }

    var sampleData: Data {
        Data()
    }

    var task: Moya.Task {
        .requestJSONEncodable(request.body)
    }

    /// 429/503 fail validation, so they reach WalletKit's retrier.
    var validationType: ValidationType {
        .successCodes
    }
}

// MARK: - Client

/// Raw `/info` responses, so tests can serve recorded fixtures.
protocol HyperliquidInfoClient: Sendable {
    func data(_ request: HyperliquidRequest, network: HyperliquidNetwork) async throws -> Data
}

extension HyperliquidInfoClient {
    func decoded<Value: Decodable>(
        _ request: HyperliquidRequest,
        network: HyperliquidNetwork,
        as type: Value.Type = Value.self
    ) async throws -> Value {
        try await data(request, network: network).decoded()
    }
}

struct LiveHyperliquidInfoClient: HyperliquidInfoClient {
    static let shared = LiveHyperliquidInfoClient()

    private let mainnet: MoyaProvider<HyperliquidTarget>
    private let testnet: MoyaProvider<HyperliquidTarget>

    init(configuration: URLSessionConfiguration = .default, bucket: HyperliquidWeightAdapter.Bucket = .standard) {
        mainnet = Self.makeProvider(network: .mainnet, configuration: configuration, bucket: bucket)
        testnet = Self.makeProvider(network: .testnet, configuration: configuration, bucket: bucket)
    }

    /// The one provider factory: WalletKit's gate and retry policy first,
    /// then the weight budget, on every attempt.
    static func makeProvider(
        network: HyperliquidNetwork,
        configuration: URLSessionConfiguration,
        bucket: HyperliquidWeightAdapter.Bucket
    ) -> MoyaProvider<HyperliquidTarget> {
        let weights = HyperliquidWeightAdapter(bucket: bucket)

        return RateGateRegistry.shared.makeProvider(
            origin: network.origin,
            provider: .jsonRPC,
            configuration: configuration,
            adapters: [weights],
            eventMonitors: [weights]
        )
    }

    func data(_ request: HyperliquidRequest, network: HyperliquidNetwork) async throws -> Data {
        let provider = network == .mainnet ? mainnet : testnet
        return try await provider.requestData(HyperliquidTarget(network: network, request: request))
    }
}
