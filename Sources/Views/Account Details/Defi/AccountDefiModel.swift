//
//  AccountDefiModel.swift
//  Reefr Wallet
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation
import SwiftUI

/// The account's stored DeFi positions and whether the DeFi tab applies. See ADR-073.
@MainActor
@Observable
final class AccountDefiModel {
    private(set) var isEligible = false
    private(set) var isLoaded = false
    private(set) var positions: [DefiPosition] = []

    let account: Account

    private let databaseService = DI.injectOrFail(DatabaseService.self)

    init(_ account: Account) {
        self.account = account
    }

    var isCandidate: Bool {
        DefiPlugins.all.contains { $0.isCandidate(account) }
    }

    var kinds: [DefiPluginKind] {
        DefiPluginKind.allCases.filter { kind in positions.contains { $0.kind == kind } }
    }

    /// Positions missing a price for some nonzero part.
    var partlyUnpricedCount: Int {
        positions.count { !$0.isUSDValueComplete }
    }

    /// The sum of every position's priced parts.
    var totalUSDValue: Decimal {
        positions.compactMap(\.usdValue).reduce(0, +)
    }

    func positions(of kind: DefiPluginKind) -> [DefiPosition] {
        positions.filter { $0.kind == kind }
    }

    /// Follows the committed NFT snapshot (for eligibility) and the stored positions.
    func observe() async {
        guard isCandidate else {
            return
        }

        let account = account
        let container = databaseService.modelContainer

        await container.observeSaves(affecting: ["DefiPositionModel", "NFTScanModel"]) {
            let (scanStates, positions) = try await container.readSnapshot { reader in
                try await (reader.fetchNFTScanStates(account: account), reader.fetchDefiPositions(account: account))
            }

            isEligible = DefiPlugins.all.contains { $0.isEligible(account, scanStates: scanStates) }
            self.positions = positions
            isLoaded = true
        }
    }
}
