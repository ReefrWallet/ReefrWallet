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
    let filter: AccountFilter
    let myAddresses: Set<String>
    let searchText: String

    @Query private var transactions: [WalletTransactionModel]
    @State private var rows: [TransactionRowModel] = []

    init(
        _ account: Account,
        filter: AccountFilter = AccountFilter(),
        myAddresses: Set<String> = [],
        searchText: String = ""
    ) {
        guard let accountId = account.id else {
            preconditionFailure()
        }

        self.account = account
        self.filter = filter
        self.myAddresses = myAddresses
        self.searchText = searchText

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
        #if os(iOS)
        let visibleRows = filteredRows

        AccountCountLabel(text: countText(visibleRows.count))
            .accessibilityIdentifier("account-transactions-count")
            .task(id: refreshId) {
                loadRows()
            }

        if transactions.isEmpty {
            AccountEmptyRow(title: .transactionsNoTransactions)
                .accessibilityIdentifier("account-no-transactions")
        } else {
            self.rows(visibleRows)
        }
        #else
        VStack {
            Text(countText(transactions.count))
                .accessibilityIdentifier("account-transactions-count")
                .style(.mediumHeader, foreground: .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading)

            Group {
                if transactions.isEmpty {
                    EmptyStateView(.transactionsNoTransactions)
                        .accessibilityIdentifier("account-no-transactions")
                } else {
                    TransactionsTable(rows: rows, schema: presenter.schema)
                }
            }
            .task(id: refreshId) {
                loadRows()
            }
        }
        #endif
    }

    private func loadRows() {
        let presenter = presenter

        rows = transactions.compactMap { transaction in
            guard let transaction = try? WalletTransaction(model: transaction) else {
                return nil
            }

            return presenter.makeRowModel(transaction, account: account)
        }
    }

    private func rows(_ models: [TransactionRowModel]) -> some View {
        ForEach(models) { model in
            TransactionRow(model: model)
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
        }
    }

    private var filteredRows: [TransactionRowModel] {
        let query = searchText.trimmingCharacters(in: .whitespaces)

        return rows.filter { model in
            guard filter.includes(model, myAddresses: myAddresses) else {
                return false
            }

            return query.isEmpty
                || model.title.localizedCaseInsensitiveContains(query)
                || model.subtitle.localizedCaseInsensitiveContains(query)
                || model.identifier.localizedCaseInsensitiveContains(query)
                || (model.method?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private func countText(_ count: Int) -> String {
        if transactions.count == Self.fetchLimit, !filter.restrictsTransactions {
            String(localized: .transactionsLatestTransactions(count))
        } else {
            String(localized: .transactionsTransactionCount(count))
        }
    }

    private var presenter: any TransactionRowPresenter {
        TransactionRowPresenters.presenter(for: account.blockchain)
    }

    private var refreshId: String {
        transactions
            .map { "\($0.persistentModelID)-\($0.status)-\($0.blockHeight ?? 0)-\($0.fee ?? "")" }
            .joined(separator: "|")
    }
}
