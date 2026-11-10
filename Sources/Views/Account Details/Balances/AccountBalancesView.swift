//
//  AccountBalancesView.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 17.09.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI

/// Mail-style list of token balances: name and amount, then unit price and USD value.
struct AccountBalancesView: View {
    let balances: [Balance]
    let hiddenBalances: [Balance]
    let hasHiddenBalances: Bool
    let isLoaded: Bool
    let totalUSDValue: Decimal?

    @Binding var selection: String?

    let onBalanceAppear: (Balance.ID) -> Void
    let onHiddenBalanceAppear: (Balance.ID) -> Void
    let onOpenHidden: () async -> Void
    let onSort: ([BalanceListSort]) -> Void

    var body: some View {
        #if os(macOS)
        AccountBalancesTable(
            balances: balances,
            hiddenBalances: hiddenBalances,
            hasHiddenBalances: hasHiddenBalances,
            isLoaded: isLoaded,
            totalUSDValue: totalUSDValue,
            selection: $selection,
            onBalanceAppear: onBalanceAppear,
            onHiddenBalanceAppear: onHiddenBalanceAppear,
            onOpenHidden: onOpenHidden,
            onSort: onSort
        )
        #else
        let entries = balances.map(BalancesTableEntry.balance)

        AccountCountLabel(text: isLoaded ? String(localized: .accountDetailsBalanceCount(entries.count)) : "")
            .accessibilityHidden(!isLoaded)

        if !entries.isEmpty {
            rows(entries)
        } else if isLoaded {
            AccountEmptyRow(title: .commonZeroBalances)
                .accessibilityIdentifier("account-zero-balances")
        }
        #endif
    }

    private func rows(_ entries: [BalancesTableEntry]) -> some View {
        ForEach(entries) { entry in
            BalanceRow(entry: entry, isSelected: selection == entry.id)
                .contentShape(Rectangle())
                .onTapGesture {
                    selection = entry.id
                }
                .listRowBackground(selection == entry.id ? Color.accentColor : nil)
                .onAppear {
                    if case let .balance(balance) = entry {
                        onBalanceAppear(balance.id)
                    }
                }
        }
    }
}

// MARK: - BalanceRow

private struct BalanceRow: View {
    let entry: BalancesTableEntry
    let isSelected: Bool

    var body: some View {
        if case let .balance(balance) = entry {
            HStack(spacing: 12) {
                icon(balance)

                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(entry.displayName)
                            .lineLimit(1)
                            .style(.headline, foreground: .primary)

                        Spacer()

                        Text("\(entry.displayAmount) \(balance.token.symbol)")
                            .lineLimit(1)
                            .style(isPhone ? .large : .medium, foreground: .primary)
                            .accessibilityIdentifier(entry.amountAccessibilityIdentifier)
                    }

                    HStack {
                        Text(.accountDetailsUnitPrice(balance.token.symbol, entry.displayUSDPrice))
                            .lineLimit(1)

                        Spacer()

                        Text("\(entry.usdValue.formattedAbbreviated()) US$")
                            .lineLimit(1)
                    }
                    .style(.callout, foreground: entry.isIncludedInBalance ? .secondary : .secondary.opacity(0.6))
                }
            }
            .padding(.vertical, 4)
            .accessibilityIdentifier(
                balance.token.isHidden ? "balance-row-hidden-\(entry.id)" : "balance-row-visible-\(entry.id)"
            )
        }
    }

    private func icon(_ balance: Balance) -> some View {
        Group {
            if let tokenImageName = entry.tokenImageName {
                Image(tokenImageName)
                    .resizable()
            } else {
                WebImageView(url: balance.token.imageURL)
            }
        }
        .scaledToFit()
        .frame(width: isPhone ? 40 : 28, height: isPhone ? 40 : 28)
        .clipShape(Circle())
    }
}
