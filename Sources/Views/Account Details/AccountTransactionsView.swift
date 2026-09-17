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
    @Query private var transactions: [WalletTransactionModel]

    init(_ account: Account) {
        guard let accountId = account.id else {
            preconditionFailure()
        }

        let predicate = #Predicate<WalletTransactionModel> { transaction in
            transaction.account.id == accountId
        }

        _transactions = Query(
            filter: predicate,
            sort: [
                SortDescriptor(\WalletTransactionModel.timestamp, order: .reverse),
                SortDescriptor(\WalletTransactionModel.transactionIndex, order: .reverse)
            ]
        )
    }

    var body: some View {
        VStack {
            Text("\(transactions.count) Transactions")
                .accessibilityIdentifier("account-transactions-count")
                .style(.mediumHeader, foreground: .primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Table(transactions) {
                TableColumn("Index") { transaction in
                    Text(transaction.transactionIndex.map(String.init) ?? "")
                }

                TableColumn("Date") { transaction in
                    Text(transaction.timestamp?.formatted(date: .abbreviated, time: .shortened) ?? "")
                }

                TableColumn("Hash") { transaction in
                    Text(transactionHash(transaction))
                        .accessibilityIdentifier("transaction-hash-\(transactionHash(transaction))")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(.leading)
    }
}

private extension AccountTransactionsView {
    func transactionHash(_ transaction: WalletTransactionModel) -> String {
        transaction.stableID
            .split(separator: "|", maxSplits: 2)
            .last
            .map(String.init) ?? transaction.stableID
    }
}
