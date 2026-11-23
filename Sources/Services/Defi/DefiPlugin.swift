//
//  DefiPlugin.swift
//  Reefr Wallet
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation
import SwiftUI
import WalletKit

/// One kind of DeFi position for one account: reads the chain, saves records
/// and shows them. Views read the stored records only. See ADR-073.
protocol DefiPlugin: Sendable {
    associatedtype Body: View

    static var kind: DefiPluginKind { get }

    var account: Account { get }

    /// A plugin for an account on a supported blockchain, with live dependencies.
    init(account: Account)

    /// Whether the plugin can hold positions on `blockchain`; decides the DeFi tab.
    static func isSupported(_ blockchain: Blockchain) -> Bool

    /// Reads the chain, then processes and saves the account's records. Throws
    /// only for run-wide failures, which leave stored records untouched.
    func refresh() async throws

    /// The table row for one of this plugin's stored records.
    @MainActor
    @ViewBuilder
    func view(_ position: DefiPosition) -> Body
}

enum DefiPluginKind: String, CaseIterable, Codable, Sendable {
    case hyperliquid
    case uniswapV3
}

enum DefiPlugins {
    static let types: [any DefiPlugin.Type] = [HyperliquidPlugin.self, UniswapV3Plugin.self]

    /// Plugins for every supported kind on `account`'s blockchain.
    static func make(for account: Account) -> [any DefiPlugin] {
        types.filter { $0.isSupported(account.blockchain) }.map { $0.init(account: account) }
    }

    static func isSupported(_ blockchain: Blockchain) -> Bool {
        types.contains { $0.isSupported(blockchain) }
    }
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
    let key: String
    let payload: Data
    /// The sum of the position's priced parts; 0 when nothing is priced yet.
    let usdValue: Decimal
}
