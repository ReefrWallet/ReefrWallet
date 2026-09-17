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
    let keyStore: KeyStore

    @State private var cachedBalances: [Balance] = []
    @State private var isCopyContractAddressButtonActive = false
    @State private var isCopyWalletAddressButtonActive = false
    @State private var isHiddenBalancesExpanded = false
    @State private var isSendButtonActive = false
    @State private var isTransactionSheetPresented = false
    @State private var selection: String?
    @State private var sortOrder: [KeyPathComparator<BalancesTableEntry>] = []

    @FocusState private var isBalancesTableFocused: Bool

    @Query var accountBalances: [BalanceModel]

    @AppStorage("AccountBalancesTableConfig")
    private var columnCustomization: TableColumnCustomization<BalancesTableEntry>

    init(_ account: Account, keyStore: KeyStore) {
        guard let accountId = account.id else {
            preconditionFailure()
        }

        let predicate = #Predicate<BalanceModel> { item in
            item.account.id == accountId
        }
        self.account = account
        self.keyStore = keyStore

        _accountBalances = Query(filter: predicate)
    }
}

// MARK: - View

extension AccountDetailsView: View {
    var body: some View {
        // `cachedBalances` is only rebuilt when the underlying SwiftData objects change, not on every render.
        // Re-deriving `[Balance]` on every body evaluation (e.g. a table row selection) would re-fault every
        // TokenModel/AccountModel relationship and redo the BigUInt/Decimal math for the whole list.
        let entries = makeEntries(cachedBalances.filter { !$0.token.isHidden })
        let hidden = makeEntries(cachedBalances.filter { $0.token.isHidden })
        let selected = selectedBalance(in: cachedBalances)

        VStack(alignment: .leading) {
            header(cachedBalances)
                .padding()

            if !entries.isEmpty || !hidden.isEmpty {
                VStack {
                    HStack(spacing: 4) {
                        Text("Total Value:")
                            .style(.mediumHeader, foreground: .primary)

                        Text(usdValue(cachedBalances).formatted(.currency(code: "USD")))
                            .style(.mediumHeader, foreground: .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    balancesTable(entries: entries, hidden: hidden)

                    if let selected {
                        detailsBar(selected)
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
        .task(id: accountBalances.map(\.id)) {
            cachedBalances = accountBalances.compactMap { try? Balance(model: $0) }
        }
        .onChange(of: selection) {
            if let amount = selected?.decimalAmount, amount > 0 {
                isSendButtonActive = true
            } else {
                isSendButtonActive = false
            }

            // Selecting a balance should steal keyboard focus from the
            // sidebar's list so arrow keys navigate this table instead.
            if selection != nil {
                isBalancesTableFocused = true
            }
        }
        .sheet(isPresented: $isTransactionSheetPresented) {
            if let selected {
                TransferView(balance: selected)
            }
        }
    }
}

// MARK: - Subviews

private extension AccountDetailsView {
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
                        WebImageView(url: balance.token.imageURL)
                            .frame(width: 16, height: 16)
                            .clipShape(Circle())
                        Text(entry.displayName)
                    }
                    .style(.medium, foreground: .primary)
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
    }

    func header(_ balances: [Balance]) -> some View {
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
                Text(account.blockchain.networkName)

                if let derivationPath = account.derivationPath {
                    Text(verbatim: .dot)
                    Text(derivationPath)
                }

                Text(verbatim: .dot)
                Text(keyStore.name)
            }
            .style(.small, foreground: .secondary)
            .padding(.bottom, 1)

            if let balance = balances.first(where: { $0.token.isNativeToken }) {
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
}

// MARK: - Logic

private extension AccountDetailsView {
    func makeEntries(_ balances: [Balance]) -> [BalancesTableEntry] {
        balances
            .map { BalancesTableEntry.balance($0) }
            .sorted(using: sortOrder)
    }

    func selectedBalance(in balances: [Balance]) -> Balance? {
        balances.first { balance in
            guard let id = balance.id else {
                return false
            }

            return selection == "\(id)"
        }
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

/* #Preview {
    AccountDetailsView(account: .mockEth(keyStore: try! .mockLocal()))  // swiftlint:disable:this force_try
        .padding()
} */
