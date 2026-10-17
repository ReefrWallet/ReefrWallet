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

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

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
            Text(countText)
                .accessibilityIdentifier("account-transactions-count")
                .style(.mediumHeader, foreground: .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading)

            Group {
                if transactions.isEmpty {
                    EmptyStateView("No Transactions")
                        .accessibilityIdentifier("account-no-transactions")
                } else if usesTable {
                    TransactionsTable(rows: rows, schema: presenter.schema)
                } else {
                    List(rows) { model in
                        TransactionRow(model: model)
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    }
                    .listStyle(.plain)
                }
            }
            .task(id: refreshId) {
                let presenter = presenter

                rows = transactions.compactMap { transaction in
                    guard let transaction = try? WalletTransaction(model: transaction) else {
                        return nil
                    }

                    return presenter.makeRowModel(transaction, account: account)
                }
            }
        }
    }

    private var countText: String {
        transactions.count == Self.fetchLimit ? "Latest \(transactions.count) Transactions" : "\(transactions.count) Transactions"
    }

    private var presenter: any TransactionRowPresenter {
        TransactionRowPresenters.presenter(for: account.blockchain)
    }

    private var usesTable: Bool {
        #if os(macOS)
        true
        #else
        horizontalSizeClass == .regular
        #endif
    }

    private var refreshId: String {
        transactions
            .map { "\($0.persistentModelID)-\($0.status)-\($0.blockHeight ?? 0)-\($0.fee ?? "")" }
            .joined(separator: "|")
    }
}
