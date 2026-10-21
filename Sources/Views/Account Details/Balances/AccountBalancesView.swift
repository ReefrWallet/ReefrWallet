//
//  AccountBalancesView.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 17.09.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI

struct AccountBalancesView: View {
    let balances: [Balance]

    @Binding var selection: String?

    @State private var isCopyContractAddressButtonActive = false
    @State private var isHiddenBalancesExpanded = false
    @State private var sortOrder: [KeyPathComparator<BalancesTableEntry>] = []

    @FocusState private var isBalancesTableFocused: Bool

    @AppStorage("AccountBalancesTableConfig")
    private var columnCustomization: TableColumnCustomization<BalancesTableEntry>

    var body: some View {
        // `balances` is cached by AccountDetailsView so this view does not re-fault SwiftData
        // relationships or redo BigUInt/Decimal math on table selection changes.
        let entries = makeEntries(balances.filter { !$0.token.isHidden })
        let hidden = makeEntries(balances.filter { $0.token.isHidden })

        if !entries.isEmpty || !hidden.isEmpty {
            VStack {
                HStack(spacing: 4) {
                    Text("Total Value:")
                        .style(.mediumHeader, foreground: .primary)
                        .accessibilityIdentifier("account-total-value-label")

                    Text(usdValue(balances).formatted(.currency(code: "USD")))
                        .style(.mediumHeader, foreground: .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
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
            EmptyStateView("Zero Balances")
                .accessibilityIdentifier("account-zero-balances")
        }
    }
}

private extension AccountBalancesView {
    var selectedBalance: Balance? {
        balances.first { balance in
            guard let id = balance.id else {
                return false
            }

            return selection == "\(id)"
        }
    }

    // swiftlint:disable:next function_body_length
    func balancesTable(entries: [BalancesTableEntry], hidden: [BalancesTableEntry]) -> some View {
        Table(
            of: BalancesTableEntry.self,
            selection: $selection,
            sortOrder: $sortOrder,
            columnCustomization: $columnCustomization
        ) {
            TableColumn("Token", value: \.displayName) { entry in
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

                case .hiddenBalancesTitle:
                    Text(entry.displayName)
                        .style(.smallHeader, foreground: .secondary)
                        .accessibilityIdentifier("balances-table-hidden-disclosure-row")

                case .none:
                    EmptyView()
                }
            }
            .customizationID("token")

            TableColumn("Price", value: \.usdPrice) { entry in
                Text(entry.displayUSDPrice)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .style(.medium, foreground: entry.isIncludedInBalance ? .primary : .secondary)
            }
            .customizationID("balance")

            TableColumn("Balance", value: \.decimalAmount) { entry in
                Text(entry.displayAmount)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .style(.medium, foreground: entry.isIncludedInBalance ? .primary : .secondary)
                    .accessibilityIdentifier(entry.amountAccessibilityIdentifier)
            }
            .customizationID("balance")

            TableColumn("USD Value", value: \.usdValue) { entry in
                Text(entry.displayUSDValue)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .style(.medium, foreground: entry.isIncludedInBalance ? .primary : .secondary)
            }
            .customizationID("usdValue")
        } rows: {
            ForEach(entries) { balance in
                TableRow(balance)
            }

            if !hidden.isEmpty {
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

            Text(balance.usdValue?.formatted(.currency(code: "USD")) ?? "")

            if balance.token.isNativeToken != true, let address = balance.token.address {
                Text(verbatim: .dot)

                Text("Contract address: \(address)")

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

    func makeEntries(_ balances: [Balance]) -> [BalancesTableEntry] {
        balances
            .map { BalancesTableEntry.balance($0) }
            .sorted(using: sortOrder)
    }

    func usdValue(_ balances: [Balance]) -> Decimal {
        balances.reduce(into: 0) { partialResult, balance in
            partialResult += (balance.usdValue ?? 0)
        }
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
