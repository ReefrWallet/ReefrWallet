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
    @State private var isCopyWalletAddressButtonActive = false
    @State private var isSendButtonActive = false
    @State private var isTransactionSheetPresented = false
    @State private var selection: String?

    @Query var accountBalances: [BalanceModel]

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
        let selected = selectedBalance(in: cachedBalances)

        VStack(alignment: .leading) {
            header(cachedBalances)
                .padding()

            TabView {
                AccountBalancesView(balances: cachedBalances, selection: $selection)
                    .tabItem {
                        Label("Balances", systemImage: "chart.bar")
                    }

                AccountTransactionsView(account)
                    .tabItem {
                        Label("Transactions", systemImage: "list.bullet")
                    }
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
}

// MARK: - Logic

private extension AccountDetailsView {
    func selectedBalance(in balances: [Balance]) -> Balance? {
        balances.first { balance in
            guard let id = balance.id else {
                return false
            }

            return selection == "\(id)"
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
