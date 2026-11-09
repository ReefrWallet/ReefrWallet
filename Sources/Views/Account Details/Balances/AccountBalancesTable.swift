//
//  AccountBalancesTable.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 17.09.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

#if os(macOS)
import SwiftUI

/// macOS token balances table with the hidden-balances disclosure and details bar.
struct AccountBalancesTable: View {
    let balances: [Balance]
    let hiddenBalances: [Balance]
    let hasHiddenBalances: Bool
    let totalUSDValue: Decimal?

    @Binding var selection: String?

    let onBalanceAppear: (Balance.ID) -> Void
    let onHiddenBalanceAppear: (Balance.ID) -> Void
    let onOpenHidden: () async -> Void
    let onSort: ([BalanceListSort]) -> Void

    @State private var isCopyContractAddressButtonActive = false
    @State private var isHiddenBalancesExpanded = false
    @State private var sortOrder: [KeyPathComparator<BalancesTableEntry>] = []

    @FocusState private var isBalancesTableFocused: Bool

    @AppStorage("AccountBalancesTableConfig")
    private var columnCustomization: TableColumnCustomization<BalancesTableEntry>

    var body: some View {
        let entries = balances.map(BalancesTableEntry.balance)
        let hidden = hiddenBalances.map(BalancesTableEntry.balance)

        if !entries.isEmpty || hasHiddenBalances {
            VStack {
                HStack(spacing: 4) {
                    Text(.commonTotalValueLabel)
                        .style(.mediumHeader, foreground: .primary)
                        .accessibilityIdentifier("account-total-value-label")

                    if let totalUSDValue {
                        Text("\(totalUSDValue.formattedAbbreviated()) US$")
                            .style(.mediumHeader, foreground: .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.leading)

                balancesTable(entries: entries, hidden: hidden)

                if let selected = selectedBalance {
                    detailsBar(selected)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            }
            .accessibilityIdentifier("account-balances-content")
        } else {
            EmptyStateView(.commonZeroBalances)
                .accessibilityIdentifier("account-zero-balances")
        }
    }
}

private extension AccountBalancesTable {
    var selectedBalance: Balance? {
        guard let selection else {
            return nil
        }

        return balances.first { $0.idString == selection } ?? hiddenBalances.first { $0.idString == selection }
    }

    // swiftlint:disable:next function_body_length
    func balancesTable(entries: [BalancesTableEntry], hidden: [BalancesTableEntry]) -> some View {
        Table(
            of: BalancesTableEntry.self,
            selection: $selection,
            sortOrder: $sortOrder,
            columnCustomization: $columnCustomization
        ) {
            TableColumn(.commonToken, value: \.displayName) { entry in
                switch entry {
                case let .balance(balance):
                    HStack {
                        if let tokenImageName = entry.tokenImageName {
                            Image(tokenImageName)
                        } else {
                            WebImageView(url: balance.token.imageURL)
                                .frame(width: 16, height: 16)
                                .clipShape(Circle())
                        }

                        Text(entry.displayName)
                    }
                    .style(.medium, foreground: .primary)
                    .accessibilityIdentifier(
                        balance.token.isHidden ? "balance-row-hidden-\(entry.id)" : "balance-row-visible-\(entry.id)"
                    )
                    .onAppear {
                        if balance.token.isHidden {
                            onHiddenBalanceAppear(balance.id)
                        } else {
                            onBalanceAppear(balance.id)
                        }
                    }

                case .hiddenBalancesTitle:
                    Text(entry.displayName)
                        .style(.smallHeader, foreground: .secondary)
                        .accessibilityIdentifier("balances-table-hidden-disclosure-row")

                case .none:
                    EmptyView()
                }
            }
            .customizationID("token")

            TableColumn(.balancesPrice, value: \.usdPrice) { entry in
                Text(entry.displayUSDPrice)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .style(.medium, foreground: entry.isIncludedInBalance ? .primary : .secondary)
            }
            .customizationID("balance")

            TableColumn(.balancesBalance, value: \.decimalAmount) { entry in
                Text(entry.displayAmount)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .style(.medium, foreground: entry.isIncludedInBalance ? .primary : .secondary)
                    .accessibilityIdentifier(entry.amountAccessibilityIdentifier)
            }
            .customizationID("balance")

            TableColumn(.commonUsdValue, value: \.usdValue) { entry in
                Text(entry.displayUSDValue)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .style(.medium, foreground: entry.isIncludedInBalance ? .primary : .secondary)
            }
            .customizationID("usdValue")
        } rows: {
            ForEach(entries) { balance in
                TableRow(balance)
            }

            if hasHiddenBalances {
                DisclosureTableRow(.hiddenBalancesTitle, isExpanded: $isHiddenBalancesExpanded) {
                    Optional<TableRow<BalancesTableEntry>>.none
                }

                if isHiddenBalancesExpanded {
                    ForEach(hidden) { balance in
                        TableRow(balance)
                    }
                }
            }
        }
        .focused($isBalancesTableFocused)
        .task(id: isHiddenBalancesExpanded) {
            if isHiddenBalancesExpanded {
                await onOpenHidden()
            }
        }
        .onChange(of: sortOrder) {
            onSort(sortOrder.map { comparator in
                let field: BalanceListSort.Field = switch comparator.keyPath {
                case \BalancesTableEntry.decimalAmount: .amount
                case \BalancesTableEntry.usdPrice: .price
                case \BalancesTableEntry.usdValue: .value
                default: .name
                }

                return BalanceListSort(field: field, ascending: comparator.order == .forward)
            })
        }
        .onChange(of: selection) {
            // Selecting a balance should steal keyboard focus from the sidebar
            // so arrow keys navigate this table instead.
            if selection != nil {
                isBalancesTableFocused = true
            }
        }
    }

    @ViewBuilder
    func detailsBar(_ balance: Balance) -> some View {
        HStack {
            Text("\(balance.decimalAmount.description) \(balance.token.symbol)")

            Text(verbatim: .dot)

            Text(balance.usdValue.map { "\($0.formattedAbbreviated()) US$" } ?? "")

            if balance.token.isNativeToken != true, let address = balance.token.address {
                Text(verbatim: .dot)

                Text(.balancesContractAddress(address))

                Image(systemName: "square.on.square")
                    .symbolEffect(.bounce, value: isCopyContractAddressButtonActive)
                    .onTapGesture {
                        copyToClipboard(address)
                        isCopyContractAddressButtonActive.toggle()
                    }
            }
        }
        .style(.medium, foreground: .secondary)
    }

    func copyToClipboard(_ string: String) {
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
        #elseif os(iOS)
        UIPasteboard.general.string = string
        #endif
    }
}
#endif
