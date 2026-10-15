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
}

extension TransactionHistorySource {
    var providesForwardHistory: Bool {
        false
    }
}
