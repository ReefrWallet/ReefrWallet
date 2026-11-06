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
    var stakedUSDValue: Decimal = 0

    @Binding var selection: String?

    var body: some View {
        #if os(macOS)
        AccountBalancesTable(balances: balances, stakedUSDValue: stakedUSDValue, selection: $selection)
        #else
        // `balances` is cached by AccountDetailsView so this view does not re-fault SwiftData
        // relationships or redo BigUInt/Decimal math on selection changes.
        let entries = balances
            .map { BalancesTableEntry.balance($0) }
            .sorted { $0.usdValue > $1.usdValue }

        AccountCountLabel(text: String(localized: .accountDetailsBalanceCount(entries.count)))

        if entries.isEmpty {
            AccountEmptyRow(title: .commonZeroBalances)
                .accessibilityIdentifier("account-zero-balances")
        } else {
            rows(entries)
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
