//
//  AccountDetailsView.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 28.12.25.
//  Copyright © 2025 Reefr Wallet. All rights reserved.
//

import SwiftData
import SwiftUI
import WalletKit

// MARK: - AccountDetailsView

struct AccountDetailsView {
    let account: Account
    let keyStore: KeyStore

    @State private var cachedBalances: [Balance] = []
    @State private var isCopyWalletAddressButtonActive = false
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
                        Label("Token Balances", systemImage: "chart.bar")
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
            .disabled(!canSend(selected))
            .accessibilityIdentifier("account-send-button")
        }

        // Balance refreshes update `BalanceModel` in place, so its persistent
        // identifier does not change when the on-chain amount changes. Include
        // the serialized amount in the task identity so the cached value list
        // is rebuilt after every successful blockchain refresh.
        .task(id: balanceRefreshId) {
            cachedBalances = accountBalances.compactMap { try? Balance(model: $0) }
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
    /// `account.address` for Bitcoin is the account's whole descriptor
    /// (`wpkh(...)`/`tr(...)`/`addr(...)`), not a human-facing address —
    /// this decodes it to the first external (index 0) address instead.
    /// A simplification: it always shows index 0, not the first address
    /// the resolver's gap-limit scan finds unused (which would need a
    /// live backend call this offline-only computed property avoids).
    var displayAddress: String {
        switch account.blockchain {
        case let .bitcoin(network):
            guard let descriptor = try? BitcoinDescriptor(string: account.address, network: network),
                  let address = try? descriptor.deriveAddress(chain: 0, index: 0) else {
                return account.address
            }

            return address.string()
        case .cardano:
            return (try? CardanoAccountDescriptor(string: account.address).receiveAddress.string) ?? account.address
        default:
            return account.address
        }
    }

    var balanceRefreshId: [String] {
        accountBalances.map { balance in
            "\(balance.persistentModelID)-\(balance.serializedAmount.base64EncodedString())"
        }
    }

    func header(_ balances: [Balance]) -> some View {
        LazyVStack(alignment: .leading) {
            Text(account.name)
                .style(.largeHeader, foreground: .primary)
                .frame(alignment: .leading)
                .padding(.bottom, 4)

            HStack {
                Text(displayAddress)

                Image(systemName: "square.on.square")
                    .symbolEffect(.bounce, value: isCopyWalletAddressButtonActive)
                    .onTapGesture {
                        copyToClipboard(displayAddress)
                        isCopyWalletAddressButtonActive.toggle()
                    }
            }
            .style(.medium, foreground: .secondary)
            .padding(.bottom, 1)

            HStack {
                Text(account.blockchain.displayName)

                if let derivationPath = account.derivationPath {
                    Text(verbatim: .dot)
                    Text(derivationPath.string)
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
    var supportsTransfers: Bool {
        if case .cardano = account.blockchain {
            switch keyStore.kind {
            case .local:
                // Local Cardano signing derives Icarus keys from the BIP-39 entropy.
                return keyStore.sealedEntropy != nil
            case .trezor:
                return true
            case .watchOnly:
                return false
            }
        }

        return true
    }

    func canSend(_ balance: Balance?) -> Bool {
        guard supportsTransfers, let amount = balance?.decimalAmount else {
            return false
        }

        return amount > 0
    }

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
