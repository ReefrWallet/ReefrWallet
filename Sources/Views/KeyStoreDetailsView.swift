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

    init(_ keyStore: KeyStore) {
        self.keyStore = keyStore
    }

    var body: some View {
        Group {
            if keyStore.accounts.isEmpty {
                EmptyStateView(.commonZeroBalances)
            } else {
                accountList
            }
        }
        .navigationTitle(keyStore.name)
        #if os(macOS)
        .navigationSubtitle("\(keyStore.description) · \(formattedTotalValue)")
        #else
        .navigationBarTitleDisplayMode(.large)
        #endif
        .task(id: keyStore.id) {
            await loadAccountRows()
        }
    }
}

private extension KeyStoreDetailsView {
    /// Mail-style list: network glyph, account name and USD value.
    var accountList: some View {
        List {
            Section {
                ForEach(accountRows.sorted { $0.account.name < $1.account.name }) { row in
                    HStack(spacing: 12) {
                        row.account.blockchain.logoImage
                            .resizable()
                            .scaledToFit()
                            .frame(width: isPhone ? 28 : 20, height: isPhone ? 28 : 20)

                        Text(row.account.name)
                            .style(isPhone ? .large : .medium, foreground: .primary)

                        Spacer()

                        Text("\(row.usdValue.formattedAbbreviated()) US$")
                            .style(isPhone ? .large : .medium, foreground: .secondary)
                    }
                }
            } header: {
                Text(.keyStoreDetailsTotalValue(formattedTotalValue))
                    .style(.headline, foreground: .primary)
                    .textCase(nil)
            }
        }
        .phoneInsetGroupedListStyle()
    }

    var formattedTotalValue: String {
        "\(accountsUSDValue.formattedAbbreviated()) US$"
    }

    var accountsUSDValue: Decimal {
        accountRows.reduce(into: 0) { $0 += $1.usdValue }
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
