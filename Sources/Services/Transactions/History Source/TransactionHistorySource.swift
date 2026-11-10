//
//  TransactionHistorySource.swift
//  ReefrWallet
//
//  Created by Andrey Yurkevich on 18/09/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import WalletKit

protocol TransactionHistorySource {
    /// Whether ascending (forward-recovery) requests are served too, including
    /// inbound token transfers — not just the descending backfill.
    var providesForwardHistory: Bool { get }

    func supports(_ account: Account) -> Bool

    func transactionHistory(
        account: Account,
        request: BlockchainTransactionHistoryRequest
    ) async throws -> BlockchainTransactionPage

    /// One page of the account's ERC-20 transfers, newest first, as effects-only records, for
    /// an account whose backfill finished before it included them. `nil` when this source's
    /// backfill already covers them.
    func tokenTransferHistory(account: Account, cursor: Data?) async throws -> BlockchainTransactionPage?
}

extension TransactionHistorySource {
    var providesForwardHistory: Bool {
        false
    }

    func tokenTransferHistory(account: Account, cursor: Data?) async throws -> BlockchainTransactionPage? {
        nil
    }
}
