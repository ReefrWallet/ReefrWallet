//
//  DefiPlugin.swift
//  Reefr Wallet
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation

/// Fetches one kind of DeFi position for an account and reports what to
/// store. Views read the stored records only. See ADR-073.
protocol DefiPlugin: Sendable {
    var kind: DefiPluginKind { get }

    /// Fetches the account's positions. Throws only for run-wide failures,
    /// which leave every stored record untouched.
    func fetch(_ context: DefiPluginContext) async throws -> [DefiPositionOutcome]

    /// Whether the account's configuration could ever be eligible. The
    /// scheduler uses it to bootstrap the inputs ``isEligible(_:scanStates:)`` needs.
    func isCandidate(_ account: Account) -> Bool

    /// Whether the committed NFT snapshot makes the account's positions knowable.
    func isEligible(_ account: Account, scanStates: [NFTSourceId: NFTScanState]) -> Bool

    /// The NFT source whose scan freshness matters for `account`, if any.
    func requiredScanSource(_ account: Account, scanStates: [NFTSourceId: NFTScanState]) -> NFTSourceId?
}

enum DefiPluginKind: String, CaseIterable, Codable, Sendable {
    case uniswapV3
}

enum DefiPlugins {
    static let all: [any DefiPlugin] = [UniswapV3Plugin()]
}

/// One position's result in a plugin run.
enum DefiPositionOutcome: Equatable, Sendable {
    /// Reading failed; the stored record stays as it is.
    case failed(key: String)
    /// Confirmed gone: transferred, burned or emptied.
    case removed(key: String)
    case updated(DefiPositionRecord)

    var key: String {
        switch self {
        case let .failed(key), let .removed(key): key
        case let .updated(record): record.key
        }
    }
}

struct DefiPositionRecord: Equatable, Sendable {
    let isUSDValueComplete: Bool
    let key: String
    let payload: Data
    let usdValue: Decimal?
}

struct DefiPluginContext: Sendable {
    let account: Account
    let budget: DefiRequestBudget
    let input: DefiInput
    /// Where a run starts handing out the shared budget, so one long backfill
    /// can't starve the account's other positions.
    let rotation: Int
}

/// The number of expensive requests (history log queries) one plugin run may make.
actor DefiRequestBudget {
    private(set) var remaining: Int

    init(_ limit: Int) {
        remaining = limit
    }

    /// Takes one request from the budget; `false` once it's spent.
    func spend() -> Bool {
        guard remaining > 0 else {
            return false
        }

        remaining -= 1
        return true
    }
}
