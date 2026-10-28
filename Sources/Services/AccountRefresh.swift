//
//  AccountRefresh.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 04.11.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation

/// The manual refresh routine behind the sidebar's refresh button and pull-to-refresh.
enum AccountRefresh {
    /// Refreshes balances and approvals of `accounts`, then nudges the price scheduler.
    /// Returns when everything is done.
    static func run(_ accounts: [Account]) async {
        let approvalService = DI.injectOrFail(ApprovalService.self)
        let balancesService = DI.injectOrFail(BalancesService.self)
        let tokenPriceScheduler = DI.injectOrFail(TokenPriceScheduler.self)

        for account in accounts {
            do {
                printVerbose("Refresh: balances start \(account.name)")
                try await balancesService.updateBalances(account)
                printVerbose("Refresh: balances done \(account.name)")
            } catch {
                printError("\(account.name): \(error)")
            }

            guard approvalService.supports(account) else {
                continue
            }

            do {
                try await approvalService.updateApprovals(account)
            } catch {
                printError("\(account.name) approvals: \(error)")
            }
        }

        // Prices refresh on their own schedule; just skip the current idle wait.
        await tokenPriceScheduler.refreshNow()
    }
}
