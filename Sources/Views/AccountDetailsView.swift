//
//  AccountDetailsView.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 28.12.25.
//  Copyright © 2025 Reefr Wallet. All rights reserved.
//

import SwiftData
import SwiftUI

// MARK: - AccountDetailsView

struct AccountDetailsView {
    let account: Account

    @State private var isCopyContractAddressButtonActive = false
    @State private var isCopyWalletAddressButtonActive = false
    @State private var isHiddenBalancesExpanded = false
    @State private var isSendButtonActive = false
    @State private var isTransactionSheetPresented = false
    @State private var selection: String?
    @State private var sortOrder: [KeyPathComparator<TableEntry>] = []

    @AppStorage("AccountBalancesTableConfig") private var columnCustomization: TableColumnCustomization<TableEntry>
}

// MARK: - View

extension AccountDetailsView: View {
    var body: some View {
        VStack(alignment: .leading) {
            header
                .padding()

            if !balances.isEmpty {
                VStack {
                    HStack(spacing: 4) {
                        Text("Total Value:")
                            .style(.mediumHeader, foreground: .primary)

                        Text(account.usdValue.formatted(.currency(code: "USD")))
                            .style(.mediumHeader, foreground: .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    balancesTable

                    if let selectedBalance {
                        detailsBar(selectedBalance)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                }
                .padding(.leading)
            } else {
                Text("Zero Balances")
                    .style(.medium, foreground: .secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
        .toolbar {
            Button {
                isTransactionSheetPresented = true
            } label: {
                Label("Send", systemImage: "paperplane")
            }
            .disabled(!isSendButtonActive)
        }
        .onChange(of: selection) {
            if let amount = selectedBalance?.decimalAmount, amount > 0 {
                isSendButtonActive = true
            } else {
                isSendButtonActive = false
            }
        }
        .sheet(isPresented: $isTransactionSheetPresented) {
            if let selectedBalance {
                TransferView(balance: selectedBalance)
            }
        }
    }
}

// MARK: - Subviews

private extension AccountDetailsView {
    var balancesTable: some View {
        Table(
            of: TableEntry.self,
            selection: $selection,
            sortOrder: $sortOrder,
            columnCustomization: $columnCustomization
        ) {
            TableColumn("Token", value: \.displayName) { entry in
                switch entry {
                case let .balance(balance):
                    HStack {
                        WebImageView(url: balance.token.imageURL)
                            .frame(width: 16, height: 16)
                            .clipShape(Circle())
                        Text(entry.displayName)
                    }
                    .style(.medium, foreground: .primary)
                case .hiddenBalancesTitle:
                    Text("Hidden Balances")
                        .style(.smallHeader, foreground: .secondary)
                }
            }
            .customizationID("token")

            TableColumn("Balance", value: \.decimalAmount) { entry in
                Text(entry.displayAmount)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .style(.medium, foreground: entry.isIncludedInBalance ? .primary : .secondary)
            }
            .customizationID("balance")

            TableColumn("USD Value", value: \.usdValue) { entry in
                Text(entry.displayUSDValue)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .style(.medium, foreground: entry.isIncludedInBalance ? .primary : .secondary)
            }
            .customizationID("usdValue")
        } rows: {
            ForEach(balances) { balance in
                TableRow(balance)
            }

            if !hiddenBalances.isEmpty {
                DisclosureTableRow(.hiddenBalancesTitle, isExpanded: $isHiddenBalancesExpanded) {
                    ForEach(hiddenBalances) { balance in
                        TableRow(balance)
                    }
                }
            }
        }
    }

    var header: some View {
        LazyVStack(alignment: .leading) {
            Text(account.name)
                .style(.largeHeader, foreground: .primary)
                .frame(alignment: .leading)
                .padding(.bottom, 4)

            HStack {
                Text(account.address)

                Image(systemName: "square.on.square")
                    .symbolEffect(.bounce, value: isCopyWalletAddressButtonActive)
                    .onTapGesture {
                        copyToClipboard(account.address)
                        isCopyWalletAddressButtonActive.toggle()
                    }
            }
            .style(.medium, foreground: .secondary)
            .padding(.bottom, 1)

            HStack {
                Text(account.blockchainConfig.networkName)

                if let derivationPath = account.derivationPath {
                    Text(verbatim: .dot)
                    Text(derivationPath)
                }

                if let keyStoreName = account.keyStore?.name {
                    Text(verbatim: .dot)
                    Text(keyStoreName)
                }
            }
            .style(.small, foreground: .secondary)
            .padding(.bottom, 1)

            if let balance = account.nativeBalance {
                Text("\(balance.decimalAmount.description) \(balance.token.symbol)")
                    .style(.small, foreground: .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    func detailsBar(_ balance: Balance) -> some View {
        HStack {
            Text("\(balance.decimalAmount.description) \(balance.token.symbol)")

            Text(verbatim: .dot)

            Text(balance.usdValue.formatted(.currency(code: "USD")))

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
}

// MARK: - Logic

private extension AccountDetailsView {
    var balances: [TableEntry] {
        account.balances
            .filter { !$0.token.isHidden }
            .map { TableEntry.balance($0) }
            .sorted(using: sortOrder)
    }

    var hiddenBalances: [TableEntry] {
        account.balances
            .filter { $0.token.isHidden }
            .map { TableEntry.balance($0) }
            .sorted(using: sortOrder)
    }

    var selectedBalance: Balance? {
        account.balances.first {
            selection == "\($0.id)"
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

// MARK: - Table Entry

private enum TableEntry: Identifiable {
    case hiddenBalancesTitle
    case balance(Balance)

    var decimalAmount: Decimal {
        switch self {
        case .hiddenBalancesTitle:
            0
        case let .balance(balance):
            balance.decimalAmount
        }
    }

    var displayAmount: String {
        switch self {
        case .hiddenBalancesTitle:
            ""
        case let .balance(balance):
            balance.decimalAmount.formatted(.number)
        }
    }

    var displayName: String {
        switch self {
        case .hiddenBalancesTitle:
            "Hidden Tokens"
        case let .balance(balance):
            balance.token.name ?? balance.token.symbol
        }
    }

    var displayUSDValue: String {
        switch self {
        case .hiddenBalancesTitle:
            ""
        case let .balance(balance):
            balance.usdValue.formatted(.number.precision(.fractionLength(2)))
        }
    }

    var id: String {
        switch self {
        case .hiddenBalancesTitle:
            // we don't want this selected, so generate new id each time
            UUID().uuidString
        case let .balance(balance):
            "\(balance.id)"
        }
    }

    var isIncludedInBalance: Bool {
        if case let .balance(balance) = self {
            if let isIncludedInBalance = balance.token.isIncludedInBalance {
                return isIncludedInBalance
            } else {
                return !balance.token.isHidden
            }
        } else {
            return false
        }
    }

    var usdValue: Decimal {
        switch self {
        case .hiddenBalancesTitle:
            0
        case let .balance(balance):
            balance.usdValue
        }
    }
}

#Preview {
    AccountDetailsView(account: .mockEth(keyStore: .mockLocal()))
        .padding()
        // .frame(width: 700, height: 400)
}
