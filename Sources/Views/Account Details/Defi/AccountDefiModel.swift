//
//  AccountDefiModel.swift
//  Reefr Wallet
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation
import SwiftUI

/// The account's DeFi plugins and their stored positions. See ADR-073.
@MainActor
@Observable
final class AccountDefiModel {
    private(set) var isLoaded = false
    private(set) var positions: [DefiPosition] = []

    let account: Account
    /// Plugins for the account's blockchain; the DeFi tab shows when there are any.
    let plugins: [any DefiPlugin]

    private let databaseService = DI.injectOrFail(DatabaseService.self)

    init(_ account: Account) {
        self.account = account
        plugins = DefiPlugins.make(for: account)
    }

    var isVisible: Bool {
        !plugins.isEmpty
    }

    /// Plugins with stored positions.
    var pluginsWithPositions: [any DefiPlugin] {
        plugins.filter { plugin in positions.contains { $0.kind == type(of: plugin).kind } }
    }

    var total: Decimal {
        positions.reduce(0) { $0 + $1.usdValue }
    }

    /// The plugin's positions, most valuable first.
    func positions(of kind: DefiPluginKind) -> [DefiPosition] {
        positions.filter { $0.kind == kind }.sorted { $0.usdValue > $1.usdValue }
    }

    func observe() async {
        guard isVisible else {
            return
        }

        let account = account
        let container = databaseService.modelContainer

        await container.observeSaves(affecting: ["DefiPositionModel"]) {
            positions = try await container.readSnapshot { reader in
                try await reader.fetchDefiPositions(account: account)
            }

            isLoaded = true
        }
    }
}
