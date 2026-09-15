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

    @State private var accountRows: [AccountRow] = []
    @State private var sortOrder: [KeyPathComparator<AccountRow>] = []

    @SceneStorage("KeyStoreAccountsTableConfig")
    private var columnCustomization: TableColumnCustomization<AccountRow>

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
        .task(id: keyStore.id) {
            await loadAccountRows()
        }
    }
}

private extension KeyStoreDetailsView {
    var accountBalancesView: some View {
        VStack {
            totalValue

            Table(sortedRows, sortOrder: $sortOrder, columnCustomization: $columnCustomization) {
                TableColumn("Account", value: \.account.name) { row in
                    HStack {
                        row.account.blockchain.logoImage
                            .resizable()
                            .scaledToFit()
                            .frame(width: 16, height: 16)

                        Text("\(row.account.name)")
                    }
                }
                .customizationID("account")

                TableColumn("USD Value", value: \.usdValue) { row in
                    Text(row.usdValue.formatted(.number.precision(.fractionLength(2))))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .customizationID("usdValue")
            }
        }
    }

    var sortedRows: [AccountRow] {
        accountRows.sorted(using: sortOrder)
    }

    var accountsUSDValue: Decimal {
        accountRows.reduce(into: 0) { $0 += $1.usdValue }
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

// MARK: - Logic

private extension KeyStoreDetailsView {
    func loadAccountRows() async {
        let balancesService = DI.injectOrFail(BalancesService.self)

        var rows: [AccountRow] = []
        for account in keyStore.accounts {
            guard let accountId = account.id else {
                continue
            }

            let usdValue = (try? await balancesService.usdValue(accountId: accountId)) ?? 0
            rows.append(AccountRow(account: account, usdValue: usdValue))
        }

        accountRows = rows
    }
}

// MARK: - AccountRow

/// The account's USD value is computed on-site (via `BalancesService`) rather
/// than carried as a property on `Account`, since summing it requires
/// faulting in every balance's token relationship — too expensive to embed
/// in a value type that's converted far more often than that total is needed.
private struct AccountRow: Identifiable, Hashable {
    let account: Account
    let usdValue: Decimal

    var id: PersistentIdentifier? { account.id }
}
