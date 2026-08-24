//
//  SidebarView.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 30.12.25.
//  Copyright © 2025 Reefr Wallet. All rights reserved.
//

import SwiftData
import SwiftUI

private let localRawKind = KeyStore.Kind.local.rawValue
private let trezorRawKind = KeyStore.Kind.trezor.rawValue
private let watchOnlyRawKind = KeyStore.Kind.watchOnly.rawValue

enum PresentedSheet: Identifiable {
    case addAccount(KeyStore)
    case addKeyStore
    case addWatchOnlyAccount

    var id: String {
        UUID().uuidString
    }
}

// MARK: - SidebarView

struct SidebarView {
    @State private var deleteAccountAlertPresented = false
    @State private var deletingAccount: Account?

    @State private var deleteKeyStoreAlertPresented = false
    @State private var deletingKeyStore: KeyStore?

    @State private var editingId: PersistentIdentifier?
    @State private var editingName: String = ""

    @State private var isUpdating = false

    @Environment(\.presentSheet) private var presentSheet
    @Environment(\.sidebarSelection) private var sidebarSelection: Binding<PersistentIdentifier?>

    @Query
    var allAccounts: [AccountModel]

    @Query
    var keyStores: [KeyStoreModel]

    @Query(filter: #Predicate<KeyStoreModel> { $0.rawKind == localRawKind })
    var localKeyStores: [KeyStoreModel]

    @Query(filter: #Predicate<KeyStoreModel> { $0.rawKind == trezorRawKind })
    var hardwareKeyStores: [KeyStoreModel]

    private let databaseService = DI.injectOrFail(DatabaseService.self)
}

// MARK: - View

extension SidebarView: View {
    var body: some View {
        List(selection: sidebarSelection) {
            if !keyStores.isEmpty {
                if !hardwareKeyStores.isEmpty {
                    makeKeysSection("Hardware Keys", keyStores: hardwareKeyStores)
                }

                if !localKeyStores.isEmpty {
                    makeKeysSection("On This Computer", keyStores: localKeyStores)
                }

                if let accounts = watchOnlyKeyStore?.accounts, !accounts.isEmpty {
                    makeWatchOnlyAccountsSection("Watch-only Accounts")
                }
            } else {
                VStack(alignment: .center) {
                    Text("No keys")
                        .style(.medium, foreground: .secondary)
                        .padding()
                        .contextMenu {
                            addMenu
                        }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .toolbar {
            addMenu
            updateMenu
        }
        .alert("Confirm Delete AccountModel", isPresented: $deleteAccountAlertPresented) {
            Button("Delete") {
                if let deletingAccount {
                    sidebarSelection.wrappedValue = nil

                    Task {
                        do {
                            guard let accountId = deletingAccount.id else {
                                preconditionFailure()
                            }

                            try await databaseService.deleteAccount(id: accountId)
                        } catch {
                            printError(error)
                        }
                    }
                }

                self.deletingAccount = nil
                deleteAccountAlertPresented = false
            }

            Button("Cancel") {
                deletingAccount = nil
                deleteAccountAlertPresented = false
            }
        }
        .alert("Confirm Delete Key Store", isPresented: $deleteKeyStoreAlertPresented) {
            Button("Delete") {
                if let deletingKeyStore {
                    sidebarSelection.wrappedValue = nil

                    Task {
                        do {
                            guard let keyStoreId = deletingKeyStore.id else {
                                throw Error.notFound
                            }

                            try await databaseService.deleteKeyStore(id: keyStoreId)
                        } catch {
                            printError(error)
                        }
                    }
                }

                self.deletingKeyStore = nil
                deleteKeyStoreAlertPresented = false
            }

            Button("Cancel") {
                deletingKeyStore = nil
                deleteKeyStoreAlertPresented = false
            }
        }
    }
}

// MARK: - Subviews

private extension SidebarView {
    var addKeyMenuItem: some View {
        Button {
            presentSheet?(.addKeyStore)
        } label: {
            Label("Add Key Store", systemImage: "key")
        }
    }

    var addMenu: some View {
        Menu {
            addKeyMenuItem

            if let selectedKeyStore {
                try? addAccountMenuItem(keyStore: KeyStore(model: selectedKeyStore))
            }

            Divider()

            addWatchOnlyAccountMenuItem
        } label: {
            Label("Add", systemImage: "plus")
        }
    }

    var addWatchOnlyAccountMenuItem: some View {
        Button {
            addWatchOnlyAccount()
        } label: {
            Label("Add Watch-Only AccountModel", systemImage: "eye")
        }
    }

    var updateMenu: some View {
        Button {
            updateBalances()
        } label: {
            Label("Update", systemImage: "arrow.2.circlepath.circle")
                .symbolEffect(.rotate, value: isUpdating)
        }
        .disabled(allAccounts.isEmpty || isUpdating)
    }

    func addAccountMenuItem(keyStore: KeyStore?) -> some View {
        Button {
            if let keyStore {
                presentSheet?(.addAccount(keyStore))
            }
        } label: {
            Label("Add Blockchain AccountModel", systemImage: "person.badge.plus")
        }
        .disabled(keyStore == nil)
    }

    @ViewBuilder
    func makeAccountContextMenu(_ account: AccountModel) -> some View {
        Button {
            sidebarSelection.wrappedValue = account.id
            editingName = account.name
            editingId = account.id
        } label: {
            Label("Rename \"\(account.name)\"", systemImage: "pencil")
        }

        Divider()

        Button {
            do {
                deletingAccount = try Account(model: account)
                deleteAccountAlertPresented = true
            } catch {
                printError("Cannot initialize Account: \(error)")
            }
        } label: {
            Label("Delete \"\(account.name)\"", systemImage: "trash")
                .style(foreground: .red)
        }
    }

    func makeAccountItem(_ account: AccountModel) -> some View {
        Label {
            if editingId == account.id {
                TextField(account.name, text: $editingName)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        editingId = nil

                        Task {
                            do {
                                try await databaseService.renameAccount(id: account.id, name: editingName)
                            } catch {
                                printError(error)
                            }
                        }
                    }
            } else if sidebarSelection.wrappedValue == account.id {
                Text(account.name)
                    .onTapGesture {
                        editingName = account.name
                        editingId = account.id
                    }
            } else {
                Text(account.name)
            }
        } icon: {
            account.blockchain.blockchain.logoImage
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)
        }
        .padding(.leading)
        .contextMenu {
            makeAccountContextMenu(account)
        }
        .tag(account.id)
    }

    @ViewBuilder
    func makeKeyStoreContextMenu(_ keyStore: KeyStore) -> some View {
        Button {
            sidebarSelection.wrappedValue = keyStore.id
            editingName = keyStore.name
            editingId = keyStore.id
        } label: {
            Label("Rename \"\(keyStore.name)\"", systemImage: "pencil")
        }

        addAccountMenuItem(keyStore: keyStore)

        Divider()

        Button(role: .destructive) {
            deletingKeyStore = keyStore
            deleteKeyStoreAlertPresented = true
        } label: {
            Label("Delete \"\(keyStore.name)\"", systemImage: "trash")
                .style(foreground: .red)
        }
    }

    func makeKeyStoreItem(_ keyStore: KeyStoreModel) -> some View {
        Section {
            ForEach(keyStore.accounts.sorted()) { account in
                makeAccountItem(account)
            }
        } header: {
            if editingId == keyStore.id {
                TextField(keyStore.name, text: $editingName)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        editingId = nil

                        Task {
                            do {
                                try await databaseService.renameKeyStore(id: keyStore.id, name: editingName)
                            } catch {
                                printError(error)
                            }
                        }
                    }
            } else if sidebarSelection.wrappedValue == keyStore.id {
                Text(keyStore.name)
                    .contextMenu {
                        try? makeKeyStoreContextMenu(KeyStore(model: keyStore))
                    }
                    .onTapGesture {
                        editingName = keyStore.name
                        editingId = keyStore.id
                    }
            } else {
                Text(keyStore.name)
                    .contextMenu {
                        try? makeKeyStoreContextMenu(KeyStore(model: keyStore))
                    }
            }
        }
        .id(keyStore.id)
    }
}

// MARK: - Logic

extension SidebarView {
    var selectedAccount: AccountModel? {
        allAccounts.first { $0.id == sidebarSelection.wrappedValue }
    }

    var selectedKeyStore: KeyStoreModel? {
        keyStores.first { $0.id == sidebarSelection.wrappedValue }
    }

    var watchOnlyKeyStore: KeyStoreModel? {
        keyStores.first(where: \.isWatchOnly)
    }

    @MainActor
    func addWatchOnlyAccount() {
        Task {
            do {
                let watchOnlyKeyStore = try await databaseService.watchOnlyKeyStore()
                presentSheet?(.addAccount(watchOnlyKeyStore))
            } catch {
                printError(error)
            }
        }
    }

    func makeKeysSection(_ title: String, keyStores: [KeyStoreModel]) -> some View {
        Section(title) {
            ForEach(keyStores) { keyStore in
                makeKeyStoreItem(keyStore)
            }
        }
    }

    @MainActor @ViewBuilder
    func makeWatchOnlyAccountsSection(_ title: String) -> some View {
        if let accounts = watchOnlyKeyStore?.accounts {
            Section(title) {
                ForEach(accounts) { account in
                    makeAccountItem(account)
                }
            }
        }
    }

    func updateBalances() {
        isUpdating = true

        Task {
            let balancesService = DI.injectOrFail(BalancesService.self)

            for accountModel in allAccounts {
                do {
                    try await balancesService.updateBalances(Account(model: accountModel))
                } catch {
                    printError(error)
                }
            }
            isUpdating = false
        }
    }
}

// MARK: - Preview

#Preview {
    SidebarView()
        .listStyle(.sidebar)
        .frame(width: 350)
}
