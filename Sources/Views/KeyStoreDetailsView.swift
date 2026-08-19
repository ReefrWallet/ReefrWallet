//
//  KeyStoreDetailsView.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 12.02.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftData
import SwiftUI

struct KeyStoreDetailsView: View {
    let keyStore: KeyStore

    @State private var sortOrder: [KeyPathComparator<Account>] = []
    @SceneStorage("KeyStoreAccountsTableConfig") private var columnCustomization: TableColumnCustomization<Account>

    var body: some View {
        VStack(alignment: .leading) {
            header
                .padding()

            if let accounts = keyStore.accounts, !accounts.isEmpty {
                accountBalances
                    .padding(.leading)
            } else {
                Text("Zero Balances")
                    .style(.medium, foreground: .secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
    }
}

private extension KeyStoreDetailsView {
    var accountBalances: some View {
        VStack {
            totalValue

            Table(keyStore.accounts ?? [], sortOrder: $sortOrder, columnCustomization: $columnCustomization) {
                TableColumn("Account", value: \.name) { account in
                    HStack {
                        Image(account.blockchainConfig.systemImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 16, height: 16)

                        Text("\(account.name)")
                    }
                }
                .customizationID("account")

                TableColumn("USD Value", value: \.usdValue) { account in
                    let amount = account.usdValue.formatted(
                        .number.precision(.fractionLength(2))
                    )

                    Text(amount)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .customizationID("usdValue")
            }
            .onChange(of: sortOrder) { _, newOrder in
                keyStore.accounts?.sort(using: newOrder)
            }
        }
    }

    var header: some View {
        VStack(alignment: .leading) {
            Text(keyStore.name)
                .style(.largeHeader, foreground: .primary)
                .padding(.bottom, 4)

            Text(keyStore.description)
                .style(.medium, foreground: .secondary)
                .padding(.bottom, 1)

            let count = keyStore.accounts?.count ?? 0

            switch count {
            case 0:
                Text("No accounts")
                    .style(.small, foreground: .secondary)
            case 1:
                Text("1 account")
                    .style(.small, foreground: .secondary)
            default:
                Text("\(count) accounts")
                    .style(.small, foreground: .secondary)
            }
        }
    }

    var totalValue: some View {
        HStack(spacing: 4) {
            Text("Total Value:")
                .style(.mediumHeader, foreground: .primary)

            Text(keyStore.accountsUSDValue.formatted(.currency(code: "USD")))
                .style(.mediumHeader, foreground: .primary)

            Spacer()
        }
        .frame(alignment: .leading)
    }
}
