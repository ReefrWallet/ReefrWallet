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
    case settings

    /// Stable across re-renders; a fresh id per read makes `.sheet(item:)` re-present endlessly.
    var id: String {
        switch self {
        case let .addAccount(keyStore):
            "addAccount-\(keyStore.hashValue)"
        case .addBrowserDapp:
            "addBrowserDapp"
        case .addKeyStore:
            "addKeyStore"
        case .addWatchOnlyAccount:
            "addWatchOnlyAccount"
        case let .backUpKeyStore(keyStore):
            "backUpKeyStore-\(keyStore.hashValue)"
        case let .browser(url):
            "browser-\(url.absoluteString)"
        case .settings:
            "settings"
        }
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

    @State private var expansionOverrides: [PersistentIdentifier: Bool] = [:]
    @State private var hoverLocation: CGPoint?
    @State private var isListEditing = false
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
        styledList
            .alert(.sidebarDeleteAccountTitle, isPresented: $deleteAccountAlertPresented) {
                deleteAccountAlertActions
            }
            .alert(.sidebarDeleteKeyStoreTitle, isPresented: $deleteKeyStoreAlertPresented) {
                deleteKeyStoreAlertActions
            }
    }

    @MainActor
    private var styledList: some View {
        List(selection: sidebarSelection) {
            if !keyStores.isEmpty {
                ForEach(orderedKeyStores) { keyStore in
                    makeKeyStoreSection(keyStore)
                }

                if isPhone, isListEditing, orderedKeyStores.last?.isWatchOnly != true {
                    emptyWatchOnlySection
                }
            } else {
                VStack(alignment: .center) {
                    Text(.sidebarNoKeys)
                        .style(.medium, foreground: .secondary)
                        .padding(.vertical)

#if os(iOS)
                    Button(.sidebarNewKeyStore) {
                        presentSheet?(.addKeyStore)
                    }
                    .buttonStyle(.borderedProminent)
                    .sheetSource(PresentedSheet.addKeyStore.id)
#endif
                }
                .contextMenu {
                    addMenu
                }
                .frame(maxWidth: .infinity)
            }

            if !keyStores.isEmpty {
                ConnectedDappsSidebarSection(.sidebarConnectedDapps, isEditing: isListEditing)
            }
        }
        .listStyle(.sidebar)
#if os(macOS)
        .onContinuousHover(coordinateSpace: .global) { phase in
            switch phase {
            case let .active(location):
                hoverLocation = location
            case .ended:
                hoverLocation = nil
            }
        }
        .environment(\.sidebarHoverLocation, hoverLocation)
        .scrollContentBackground(.hidden)
        .background(Color.sidebarBackground)
#else
        .navigationTitle(isPhone ? String(localized: .sidebarKeyStores) : "")
        .navigationBarTitleDisplayMode(.large)
        .animation(.default, value: isListEditing)
        .refreshable {
            await refreshAllAccounts()
        }
#endif
        .focused($isAccountsListFocused)
        .onChange(of: sidebarSelection.wrappedValue) {
            // Switching accounts/key stores in the sidebar should steal
            // keyboard focus back from wherever it landed (e.g. the
            // balances table in AccountDetailsView), so arrow keys keep
            // navigating this list.
            if sidebarSelection.wrappedValue != nil {
                isAccountsListFocused = true
                isListEditing = false
            }
        }
        .toolbar {
#if os(iOS)
            if isListEditing {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        presentSheet?(.settings)
                    } label: {
                        Label(.commonSettings, systemImage: "gearshape")
                    }
                    .sheetSource(PresentedSheet.settings.id)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button(.commonDone) {
                        isListEditing = false
                    }
                    .buttonStyle(.borderedProminent)
                    .fontWeight(.semibold)
                }

                ToolbarItem(placement: .bottomBar) {
                    Spacer()
                }

                ToolbarItem(placement: .bottomBar) {
                    Button(.sidebarNewKeyStore) {
                        presentSheet?(.addKeyStore)
                    }
                    .sheetSource(PresentedSheet.addKeyStore.id)
                }
            } else if !keyStores.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(.commonEdit) {
                        isListEditing = true
                    }
                }
            }
#else
            addMenu
            updateMenu
#endif
        }
    }

    @ViewBuilder
    private var deleteAccountAlertActions: some View {
        Button(.sidebarDelete) {
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

        Button(.commonCancel) {
            deletingAccount = nil
            deleteAccountAlertPresented = false
        }
    }

    @ViewBuilder
    private var deleteKeyStoreAlertActions: some View {
        Button(.sidebarDelete) {
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

        Button(.commonCancel) {
            deletingKeyStore = nil
            deleteKeyStoreAlertPresented = false
        }
    }
}

// MARK: - Subviews

private extension SidebarView {
    var addKeyMenuItem: some View {
        Button {
            presentSheet?(.addKeyStore)
        } label: {
            Label(.sidebarAddKeyStore, systemImage: "key")
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

            if isPhone {
                Divider()

                Button {
                    presentSheet?(.settings)
                } label: {
                    Label(.commonSettings, systemImage: "gearshape")
                }
            }
        } label: {
            Label(.commonAdd, systemImage: "plus")
        }
        .sheetSource(PresentedSheet.addKeyStore.id)
        .accessibilityIdentifier("sidebar-add-menu")
    }

    var addWatchOnlyAccountMenuItem: some View {
        Button {
            addWatchOnlyAccount()
        } label: {
            Label(.sidebarAddWatchOnlyAccount, systemImage: "eye")
        }
        .accessibilityIdentifier("sidebar-add-watch-only-account-item")
    }

    var updateMenu: some View {
        Button {
            updateBalances()
        } label: {
            Label(.sidebarUpdate, systemImage: "arrow.2.circlepath.circle")
                .symbolEffect(.rotate, value: isUpdating)
        }
        .disabled(allAccounts.isEmpty || isUpdating)
        .accessibilityIdentifier("sidebar-update-button")
    }

    func addAccountMenuItem(keyStore: KeyStore) -> some View {
        Button {
            presentSheet?(.addAccount(keyStore))
        } label: {
            Label(.sidebarAddAccountOnKeyStore(keyStore.name), systemImage: "person.badge.plus")
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
            Label(.sidebarRenameItem(account.name), systemImage: "pencil")
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
            Label(.sidebarDeleteItem(account.name), systemImage: "trash")
                .style(foreground: .negative)
        }
    }

    @MainActor @ViewBuilder
    func makeAccountItem(_ account: AccountModel) -> some View {
        if isPhone {
            KeyStoreAccountRow(account: account, isEditing: isListEditing) {
                if let account = try? Account(model: account) {
                    deletingAccount = account
                    deleteAccountAlertPresented = true
                }
            }
            .tag(account.id)
            .selectionDisabled(isListEditing)
            .phoneRowNeverHighlighted()
        } else {
            makeMacAccountItem(account)
        }
    }

    func makeMacAccountItem(_ account: AccountModel) -> some View {
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
            Label(.sidebarDeleteItem(keyStore.name), systemImage: "trash")
        }

        Divider()

        Button {
            presentSheet?(.backUpKeyStore(keyStore))
        } label: {
            Label(.sidebarBackUpKeyStore(keyStore.name), systemImage: "externaldrive.badge.timemachine")
        }
        .disabled(!keyStore.isLocal)

        Button {
            sidebarSelection.wrappedValue = keyStore.id
            editingName = keyStore.name
            editingId = keyStore.id
        } label: {
            Label(.sidebarRenameItem(keyStore.name), systemImage: "pencil")
        }
    }

    @MainActor @ViewBuilder
    func makeKeyStoreSection(_ keyStore: KeyStoreModel) -> some View {
        SidebarSection(isExpanded: expansionBinding(keyStore)) {
#if os(macOS)
            SidebarAddButton(
                accessibilityLabel: .commonAddAccount,
                accessibilityId: "sidebar-add-account-button-\(keyStore.name)",
                trailingPadding: 0
            ) {
                addAccount(to: keyStore)
            }
#endif
        } content: {
            ForEach(keyStore.accounts.sorted()) { account in
                makeAccountItem(account)
            }

            if isPhone, isListEditing {
                EditModeButton(
                    kind: .add,
                    accessibilityLabel: .sidebarAddAccountRow,
                    title: .sidebarAddAccountRow
                ) {
                    addAccount(to: keyStore)
                }
                .phoneRowNeverHighlighted()
                .selectionDisabled()
                .sheetSource(addAccountSourceId(keyStore))
            }
        } title: {
            makeKeyStoreTitle(keyStore)
        } trailing: {
            if !keyStore.isWatchOnly, !(expansionOverrides[keyStore.id] ?? !keyStore.isCollapsed) {
                Text(totalValue(keyStore).formatted(.currency(code: "USD")))
                    .style(
                        isPhone ? .large : .small,
                        foreground: isPhone ? .phoneSecondaryLabel : .sidebarSecondaryLabel
                    )
            }
        }
        .id(keyStore.id)
    }

    /// Edit-mode stand-in for the watch-only section while it has no accounts.
    @MainActor
    var emptyWatchOnlySection: some View {
        Section {
            EditModeButton(
                kind: .add,
                accessibilityLabel: .sidebarAddAccountRow,
                title: .sidebarAddAccountRow
            ) {
                addWatchOnlyAccount()
            }
            .phoneRowNeverHighlighted()
            .selectionDisabled()
            .sheetSource(watchOnlyKeyStore.map(addAccountSourceId) ?? PresentedSheet.addWatchOnlyAccount.id)
        } header: {
            Text(.sidebarWatchOnlyAccounts)
                .style(.title, foreground: .phoneLabel)
        }
    }

    @MainActor
    func makeKeyStoreTitle(_ keyStore: KeyStoreModel) -> some View {
        HStack(spacing: isPhone ? 12 : 4) {
            if isPhone, isListEditing, !keyStore.isWatchOnly {
                EditModeButton(kind: .remove, accessibilityLabel: .commonRemove) {
                    if let keyStore = try? KeyStore(model: keyStore) {
                        deletingKeyStore = keyStore
                        deleteKeyStoreAlertPresented = true
                    }
                }
            }

            keyStoreTitle(keyStore)
        }
        .style(foreground: isPhone ? .phoneLabel : .sidebarLabel)
    }

    @ViewBuilder
    func keyStoreTitle(_ keyStore: KeyStoreModel) -> some View {
        let title = keyStore.isWatchOnly ? String(localized: .sidebarWatchOnlyAccounts) : keyStore.name

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
        } else if isPhone {
            Text(title)
                .style(.title, foreground: .phoneLabel)
                .lineLimit(1)
                .truncationMode(.tail)
        } else if sidebarSelection.wrappedValue == keyStore.id {
            Text(title)
                .contextMenu {
                    try? makeKeyStoreContextMenu(KeyStore(model: keyStore))
                }
                .onTapGesture {
                    editingName = keyStore.name
                    editingId = keyStore.id
                }
        } else {
            Text(title)
                .contextMenu {
                    try? makeKeyStoreContextMenu(KeyStore(model: keyStore))
                }
        }
    }

    func expansionBinding(_ keyStore: KeyStoreModel) -> Binding<Bool> {
        let databaseService = databaseService
        let id = keyStore.id
        let overrides = $expansionOverrides

        return Binding(
            get: { overrides.wrappedValue[id] ?? !keyStore.isCollapsed },
            set: { isExpanded in
                // Apply synchronously so the toggle animates; the database write lands later.
                withAnimation {
                    overrides.wrappedValue[id] = isExpanded
                }

                Task {
                    do {
                        try await databaseService.setKeyStoreCollapsed(id: id, isCollapsed: !isExpanded)
                    } catch {
                        printError(error)
                    }
                }
            }
        )
    }

    func totalValue(_ keyStore: KeyStoreModel) -> Decimal {
        keyStore.accounts.reduce(into: 0) { $0 += $1.usdValue() }
    }

    func addAccountSourceId(_ keyStore: KeyStoreModel) -> String {
        guard let keyStore = try? KeyStore(model: keyStore) else {
            return PresentedSheet.addKeyStore.id
        }

        return PresentedSheet.addAccount(keyStore).id
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

    var orderedKeyStores: [KeyStoreModel] {
        var result = hardwareKeyStores + localKeyStores

        if let watchOnlyKeyStore, !watchOnlyKeyStore.accounts.isEmpty {
            result.append(watchOnlyKeyStore)
        }

        return result
    }

    @MainActor
    func addAccount(to keyStore: KeyStoreModel) {
        if keyStore.isWatchOnly {
            addWatchOnlyAccount()
        } else if let keyStore = try? KeyStore(model: keyStore) {
            presentSheet?(.addAccount(keyStore))
        }
    }

    func updateBalances() {
        isUpdating = true

        Task {
            await refreshAllAccounts()
            isUpdating = false
        }
    }

    func refreshAllAccounts() async {
        let accounts = allAccounts.compactMap { accountModel -> Account? in
            do {
                return try Account(model: accountModel)
            } catch {
                printError("Cannot create account model: \(error)")
                return nil
            }
        }

        await AccountRefresh.run(accounts)
    }
} // swiftlint:disable:this file_length
