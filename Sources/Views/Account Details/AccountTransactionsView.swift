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
                .padding(.leading)

            Table(transactions) {
                TableColumn("Digest") { transaction in
                    Text(transaction.identifier)
                        .accessibilityIdentifier("transaction-hash-\(transaction.identifier)")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                TableColumn("Method") { transaction in
                    Text(method(transaction))
                        .accessibilityIdentifier("transaction-method-\(transaction.identifier)")
                }

                TableColumn("Block") { transaction in
                    Text(transaction.blockHeight.map(String.init) ?? "")
                        .accessibilityIdentifier("transaction-block-\(transaction.identifier)")
                }

                TableColumn("From") { transaction in
                    Text(transaction.sender ?? "")
                        .accessibilityIdentifier("transaction-from-\(transaction.identifier)")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                TableColumn("To") { transaction in
                    Text(transaction.recipient ?? "")
                        .accessibilityIdentifier("transaction-to-\(transaction.identifier)")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }
}

private extension AccountTransactionsView {
    func method(_ transaction: WalletTransactionModel) -> String {
        transaction.effects.first?.kind ?? ""
    }
}
