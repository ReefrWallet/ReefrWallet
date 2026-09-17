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

    @FocusState private var isAccountsListFocused: Bool

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

    private let accountService = DI.injectOrFail(AccountService.self)
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
        .focused($isAccountsListFocused)
        .onChange(of: sidebarSelection.wrappedValue) {
            // Switching accounts/key stores in the sidebar should steal
            // keyboard focus back from wherever it landed (e.g. the
            // balances table in AccountDetailsView), so arrow keys keep
            // navigating this list.
            if sidebarSelection.wrappedValue != nil {
                isAccountsListFocused = true
            }
        }
        .toolbar {
            addMenu
            updateMenu
        }
        .alert("Confirm Delete Account", isPresented: $deleteAccountAlertPresented) {
            Button("Delete") {
                if let deletingAccount {
                    sidebarSelection.wrappedValue = nil

                    Task {
                        do {
                            try await accountService.deleteAccount(deletingAccount)
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

// MARK: - SidebarAccountRow

/// Narrow, value-type inputs so SwiftUI can skip re-running `body` (and
/// re-touching `account.blockchain`, a SwiftData relationship fault +
/// decode) for rows whose selection/editing state didn't change.
private struct SidebarAccountRow: View {
    let account: AccountModel
    @Binding var editingName: String

    let isEditing: () -> Bool
    let isSelected: () -> Bool
    let onSelect: () -> Void
    let onStartEditing: () -> Void
    let onCommitEditing: () -> Void

    var body: some View {
        Label {
            if isEditing() {
                TextField(account.name, text: $editingName)
                    .textFieldStyle(.plain)
                    .onSubmit(onCommitEditing)
                    .accessibilityIdentifier("sidebar-account-textfield-\(account.name)")
            } else {
                // `.onTapGesture`, not `Button`: a `Button` inside a macOS
                // `List` row needs an extra click just to make the row/List
                // the key view before its action fires, so the click right
                // after selecting only shows the press effect and does
                // nothing — a third click would be needed to actually start
                // editing. `.onTapGesture` fires on that very next click.
                // It's still race-free: this gesture is unconditionally
                // present whenever not editing, regardless of selection —
                // only the *behavior* branches on the live `isSelected()`
                // read inside the handler.
                Text(account.name)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if isSelected() {
                            onStartEditing()
                        } else {
                            onSelect()
                        }
                    }
                    .accessibilityIdentifier("sidebar-account-label-\(account.name)")
            }
        } icon: {
            account.blockchain.blockchain.logoImage
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
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
            Label("Add Watch-Only Account", systemImage: "eye")
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
            Label("Add Blockchain Account", systemImage: "person.badge.plus")
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
        SidebarAccountRow(
            account: account,
            editingName: $editingName,
            isEditing: {
                editingId == account.id
            },
            isSelected: {
                sidebarSelection.wrappedValue == account.id
            },
            onSelect: {
                sidebarSelection.wrappedValue = account.id
            },
            onStartEditing: {
                editingName = account.name
                editingId = account.id
            },
            onCommitEditing: {
                editingId = nil

                Task {
                    do {
                        try await databaseService.renameAccount(id: account.id, name: editingName)
                    } catch {
                        printError(error)
                    }
                }
            }
        )
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
                guard let account = try? Account(model: accountModel) else {
                    printError("Cannot create account model")
                    return
                }

                do {
                    try await balancesService.updateBalances(account)
                } catch {
                    printError(error)
                }

                do {
                    try await balancesService.updateTokenPrices(account)
                } catch {
                    printError(error)
                }
            }
            isUpdating = false
        }
    }
}

// MARK: - Preview

/* #Preview {
    Inject.mode = .preview
    let databaseService = DI.injectOrFail(DatabaseService.self)

    SidebarView()
        .modelContainer(databaseService.modelContainer)
        .listStyle(.sidebar)
        .frame(width: 350)
} */
