//
//  AccountTransactionsView.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 17.09.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftData
import SwiftUI

struct AccountTransactionsView: View {
    /// Caps every merge-triggered re-fetch to a bounded cost regardless of how
    /// large the account's history grows — an unbounded query here was
    /// measured (Instruments, `core-data-fetch`) taking up to 14.5ms on the
    /// main thread per re-fetch during backfill of a large history.
    static let fetchLimit = 500

    let account: Account

    @Query private var transactions: [WalletTransactionModel]
    @State private var rows: [TransactionRowModel] = []

    init(_ account: Account) {
        guard let accountId = account.id else {
            preconditionFailure()
        }

        self.account = account

        var descriptor = FetchDescriptor<WalletTransactionModel>(
            predicate: #Predicate { transaction in
                transaction.account.id == accountId
            },
            sortBy: [
                SortDescriptor(\WalletTransactionModel.timestamp, order: .reverse),
                SortDescriptor(\WalletTransactionModel.transactionIndex, order: .reverse)
            ]
        )

        descriptor.fetchLimit = Self.fetchLimit
        _transactions = Query(descriptor)
    }

    var body: some View {
        VStack {
            Text(transactions.count == Self.fetchLimit ? "Latest \(transactions.count) Transactions" : "\(transactions.count) Transactions")
                .accessibilityIdentifier("account-transactions-count")
                .style(.mediumHeader, foreground: .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading)

            List(rows) { model in
                TransactionRow(model: model, blockchain: account.blockchain)
            }
            .task(id: refreshId) {
                let presenter = TransactionRowPresenters.presenter(for: account.blockchain)

                rows = transactions.compactMap { transaction in
                    guard let transaction = try? WalletTransaction(model: transaction) else {
                        return nil
                    }

                    return presenter.makeRowModel(transaction, account: account)
                }
            }
        }
    }

    private var refreshId: String {
        transactions
            .map { "\($0.persistentModelID)-\($0.status)-\($0.blockHeight ?? 0)" }
            .joined(separator: "|")
    }
}
