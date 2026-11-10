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
    static func enqueueAllApprovals() async {
        let databaseService = DI.injectOrFail(DatabaseService.self)
        do {
            for account in try await databaseService.fetchAllAccounts() {
                enqueueApprovals(account)
            }
        } catch {
            printError("Approvals: \(error)")
        }
    }

    static func enqueueApprovals(_ account: Account) {
        switch account.blockchain {
        case .evm:
            DI.injectOrFail(EthereumApprovalService.self).enqueueRefresh(account)
        case .tron:
            DI.injectOrFail(TronApprovalService.self).enqueueRefresh(account)
        default:
            break
        }
    }

    /// Refreshes balances and approvals of `accounts`, then nudges the identity and price schedulers.
    /// Returns when everything is done.
    static func run(_ accounts: [Account]) async {
        let balancesService = DI.injectOrFail(BalancesService.self)
        let tokenIdentityScheduler = DI.injectOrFail(TokenIdentityScheduler.self)
        let tokenPriceScheduler = DI.injectOrFail(TokenPriceScheduler.self)

        for account in accounts {
            do {
                printVerbose("Refresh: balances start \(account.name)")
                try await balancesService.updateBalances(account)
                printVerbose("Refresh: balances done \(account.name)")
            } catch {
                printError("\(account.name): \(error)")
            }

            do {
                try await updateApprovals(account)
            } catch {
                printError("\(account.name) approvals: \(error)")
            }
        }

        // Identities and prices refresh on their own schedule; just skip the current idle wait.
        await tokenIdentityScheduler.refreshNow()
        await tokenPriceScheduler.refreshNow()
    }

    private static func updateApprovals(_ account: Account) async throws {
        switch account.blockchain {
        case .evm:
            let service = DI.injectOrFail(EthereumApprovalService.self)
            if service.supports(account) {
                try await service.updateApprovals(account)
            }

        case .tron:
            try await DI.injectOrFail(TronApprovalService.self).updateApprovals(account)
        default:
            break
        }
    }
}
