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
    private let keyStore: KeyStore

    @State private var sortOrder: [KeyPathComparator<Account>] = []

    @SceneStorage("KeyStoreAccountsTableConfig")
    private var columnCustomization: TableColumnCustomization<Account>

    init(_ keyStore: KeyStore) {
        self.keyStore = keyStore
    }

    var body: some View {
        VStack(alignment: .leading) {
            header
                .padding()

            if !keyStore.accounts.isEmpty {
                accountBalancesView
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
    var accountBalancesView: some View {
        VStack {
            totalValue

            Table(sortedAccounts, sortOrder: $sortOrder, columnCustomization: $columnCustomization) {
                TableColumn("Account", value: \.name) { account in
                    HStack {
                        account.blockchain.logoImage
                            .resizable()
                            .scaledToFit()
                            .frame(width: 16, height: 16)

                        Text("\(account.name)")
                    }
                }
                .customizationID("account")

                TableColumn("USD Value", value: \.usdValue) { account in
                    Text(account.usdValue.formatted(.number.precision(.fractionLength(2))))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .customizationID("usdValue")
            }
        }
    }

    var sortedAccounts: [Account] {
        keyStore.accounts.sorted(using: sortOrder)
    }

    var accountsUSDValue: Decimal {
        keyStore.accounts.reduce(0) { $0 + $1.usdValue }
    }

    var header: some View {
        VStack(alignment: .leading) {
            Text(keyStore.name)
                .style(.largeHeader, foreground: .primary)
                .padding(.bottom, 4)

            Text(keyStore.description)
                .style(.medium, foreground: .secondary)
                .padding(.bottom, 1)

            let count = keyStore.accounts.count

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

            Text(accountsUSDValue.formatted(.currency(code: "USD")))
                .style(.mediumHeader, foreground: .primary)

            Spacer()
        }
        .frame(alignment: .leading)
    }
}
