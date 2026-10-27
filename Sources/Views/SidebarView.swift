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
    case addBrowserDapp
    case addKeyStore
    case addWatchOnlyAccount
    case backUpKeyStore(KeyStore)
    case browser(URL)

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
    private let keyStoreService = DI.injectOrFail(KeyStoreService.self)
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
                        .padding(.vertical)
                }
                .contextMenu {
                    addMenu
                }
                .frame(maxWidth: .infinity)
            }

            if !keyStores.isEmpty {
                ConnectedDappsSidebarSection("Connected dApps")
            }
        }
        #if os(macOS)
        .scrollContentBackground(.hidden)
        .background(Color.sidebarBackground)
        #endif
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
                            printError("\(deletingAccount.name): \(error)")
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
                            try await keyStoreService.deleteKeyStore(deletingKeyStore)
                        } catch {
                            printError("\(deletingKeyStore.name): \(error)")
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
            if let selectedKeyStore,
               !selectedKeyStore.isWatchOnly,
               let keyStore = try? KeyStore(model: selectedKeyStore) {
                addAccountMenuItem(keyStore: keyStore)

                Divider()
            }

            addKeyMenuItem

            Divider()

            addWatchOnlyAccountMenuItem
        } label: {
            Label("Add", systemImage: "plus")
        }
        .accessibilityIdentifier("sidebar-add-menu")
    }

    var addWatchOnlyAccountMenuItem: some View {
        Button {
            addWatchOnlyAccount()
        } label: {
            Label("Add Watch-Only Account", systemImage: "eye")
        }
        .accessibilityIdentifier("sidebar-add-watch-only-account-item")
    }

    var updateMenu: some View {
        Button {
            updateBalances()
        } label: {
            Label("Update", systemImage: "arrow.2.circlepath.circle")
                .symbolEffect(.rotate, value: isUpdating)
        }
        .disabled(allAccounts.isEmpty || isUpdating)
        .accessibilityIdentifier("sidebar-update-button")
    }

    func addAccountMenuItem(keyStore: KeyStore) -> some View {
        Button {
            presentSheet?(.addAccount(keyStore))
        } label: {
            Label("Add Blockchain Account on \(keyStore.name)", systemImage: "person.badge.plus")
        }
    }

    @ViewBuilder
    func makeAccountContextMenu(_ account: AccountModel) -> some View {
        if !account.keyStore.isWatchOnly, let keyStore = try? KeyStore(model: account.keyStore) {
            addAccountMenuItem(keyStore: keyStore)

            Divider()
        }

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
                printError(error)
            }
        } label: {
            Label("Delete \"\(account.name)\"", systemImage: "trash")
                .style(foreground: .negative)
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
        addAccountMenuItem(keyStore: keyStore)

        Divider()

        Button(role: .destructive) {
            deletingKeyStore = keyStore
            deleteKeyStoreAlertPresented = true
        } label: {
            Label("Delete \"\(keyStore.name)\"", systemImage: "trash")
        }

        Divider()

        Button {
            presentSheet?(.backUpKeyStore(keyStore))
        } label: {
            Label("Back Up \"\(keyStore.name)\"", systemImage: "externaldrive.badge.timemachine")
        }
        .disabled(!keyStore.isLocal)

        Button {
            sidebarSelection.wrappedValue = keyStore.id
            editingName = keyStore.name
            editingId = keyStore.id
        } label: {
            Label("Rename \"\(keyStore.name)\"", systemImage: "pencil")
        }
    }

    func makeKeyStoreItem(_ keyStore: KeyStoreModel) -> some View {
        Section {
            ForEach(keyStore.accounts.sorted()) { account in
                makeAccountItem(account)
            }
        } header: {
            HStack(spacing: 4) {
                KeyStoreKindIcon(kind: keyStore.kind, model: keyStore.model)
                    .style(foreground: .sidebarControl)

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

                Spacer()

                SidebarAddButton(
                    accessibilityLabel: "Add Account",
                    accessibilityId: "sidebar-add-account-button-\(keyStore.name)",
                    trailingPadding: -6
                ) {
                    if let keyStore = try? KeyStore(model: keyStore) {
                        presentSheet?(.addAccount(keyStore))
                    }
                }
            }
            .style(foreground: .sidebarLabel)
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
        selectedAccount?.keyStore ?? keyStores.first { $0.id == sidebarSelection.wrappedValue }
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
        Section {
            ForEach(keyStores) { keyStore in
                makeKeyStoreItem(keyStore)
            }
        } header: {
            Text(title)
                .style(foreground: .sidebarSecondaryLabel)
        }
    }

    @MainActor @ViewBuilder
    func makeWatchOnlyAccountsSection(_ title: String) -> some View {
        if let accounts = watchOnlyKeyStore?.accounts {
            Section {
                ForEach(accounts) { account in
                    makeAccountItem(account)
                }
            } header: {
                HStack {
                    Text(title)
                        .style(foreground: .sidebarSecondaryLabel)

                    Spacer()

                    SidebarAddButton(
                        accessibilityLabel: "Add Watch-Only Account",
                        accessibilityId: "sidebar-add-watch-only-account-button"
                    ) {
                        addWatchOnlyAccount()
                    }
                }
            }
        }
    }

    func updateBalances() {
        isUpdating = true

        let accounts = allAccounts.compactMap { accountModel -> Account? in
            do {
                return try Account(model: accountModel)
            } catch {
                printError("Cannot create account model: \(error)")
                return nil
            }
        }

        Task {
            let approvalService = DI.injectOrFail(ApprovalService.self)
            let balancesService = DI.injectOrFail(BalancesService.self)
            let tokenPriceScheduler = DI.injectOrFail(TokenPriceScheduler.self)

            for account in accounts {
                do {
                    printVerbose("Refresh: balances start \(account.name)")
                    try await balancesService.updateBalances(account)
                    printVerbose("Refresh: balances done \(account.name)")
                } catch {
                    printError("\(account.name): \(error)")
                }

                guard approvalService.supports(account) else {
                    continue
                }

                do {
                    try await approvalService.updateApprovals(account)
                } catch {
                    printError("\(account.name) approvals: \(error)")
                }
            }

            // Prices refresh on their own schedule; just skip the current idle wait.
            await tokenPriceScheduler.refreshNow()

            isUpdating = false
        }
    }
}
