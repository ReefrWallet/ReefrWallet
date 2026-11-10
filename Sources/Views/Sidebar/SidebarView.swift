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

// MARK: - Total Value Footer

#if os(macOS)
private struct SidebarTotalValueFooter: View {
    let value: Decimal?

    var body: some View {
        if let value {
            HStack {
                Text(.commonTotalValueLabel)
                    .style(.sidebarHeader, foreground: .sidebarLabel)

                Spacer()

                Text("\(value.formattedAbbreviated()) US$")
                    .style(.small, foreground: .sidebarLabel)
            }
            .padding([.vertical, .trailing])
            .padding(.leading, 14)
        }
    }
}
#endif

// MARK: - SidebarView

struct SidebarView {
    @State private var deleteAccountAlertPresented = false
    @State private var deleteAccountError: String?
    @State private var deleteAccountErrorPresented = false
    @State private var deletingAccount: Account?

    @State private var deleteKeyStoreAlertPresented = false
    @State private var deletingKeyStore: KeyStore?

    @State private var editingId: PersistentIdentifier?
    @State private var editingName: String = ""

    @State private var expansionOverrides: [PersistentIdentifier: Bool] = [:]
#if os(macOS)
    @State private var accountValues: [PersistentIdentifier: Decimal] = [:]
    @State private var hover = SidebarHover()
#endif
    @State private var isListEditing = false
    @State private var isDeletingAccount = false
    @State private var isUpdating = false

    @FocusState private var isAccountsListFocused: Bool

    @Environment(\.presentSheet) private var presentSheet
    @Environment(\.sidebarSelection) private var sidebarSelection: Binding<PersistentIdentifier?>

    @Binding var isAccountDeletionHUDPresented: Bool
    let allAccounts: [AccountModel]

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
            .alert(.commonRequestFailed, isPresented: $deleteAccountErrorPresented) {
                Button(.commonOk) {}
            } message: {
                Text(verbatim: deleteAccountError ?? "")
            }
            .alert(.sidebarDeleteKeyStoreTitle, isPresented: $deleteKeyStoreAlertPresented) {
                deleteKeyStoreAlertActions
            }
    }

    @MainActor
    private var styledList: some View {
        let accountsByKeyStore = Dictionary(grouping: allAccounts) { $0.keyStore.id }
        let orderedKeyStores = orderedKeyStores(accountsByKeyStore: accountsByKeyStore)

        return List(selection: sidebarSelection) {
            if !keyStores.isEmpty {
                ForEach(orderedKeyStores) { keyStore in
                    makeKeyStoreSection(keyStore, accounts: accountsByKeyStore[keyStore.id, default: []])
                }

                if isIOS, isListEditing, orderedKeyStores.last?.isWatchOnly != true {
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

            if !keyStores.isEmpty, !isIOS || !allAccounts.isEmpty {
                ConnectedDappsSidebarSection(
                    .sidebarConnectedDapps,
                    hasAccounts: !allAccounts.isEmpty,
                    isEditing: isListEditing
                )
            }
        }
        .listStyle(.sidebar)
#if os(macOS)
        .onContinuousHover(coordinateSpace: .global) { phase in
            switch phase {
            case let .active(location):
                hover.location.send(location)
            case .ended:
                hover.location.send(nil)
            }
        }
        .environment(\.sidebarHover, hover)
        .scrollContentBackground(.hidden)
        .background(Color.sidebarBackground)
        .statusBar(background: .sidebarBackground) {
            if !keyStores.isEmpty {
                SidebarTotalValueFooter(value: totalValueExcludingWatchOnlyAccounts())
            }
        }
        .task {
            await observeAccountValues()
        }
#else
        .navigationTitle(totalValueExcludingWatchOnlyAccounts().map { "\($0.formattedAbbreviated()) US$" } ?? "")
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
                    if isPhone {
                        doneButton.buttonStyle(.borderedProminent)
                    } else {
                        doneButton
                    }
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
                Task { await deleteAccount(deletingAccount) }
            }

            self.deletingAccount = nil
            deleteAccountAlertPresented = false
        }

        Button(.commonCancel) {
            deletingAccount = nil
            deleteAccountAlertPresented = false
        }
    }

    @MainActor
    private func deleteAccount(_ account: Account) async {
        guard !isDeletingAccount, let accountId = account.id else {
            return
        }

        isDeletingAccount = true
        defer {
            isAccountDeletionHUDPresented = false
            isDeletingAccount = false
        }

        do {
            isAccountDeletionHUDPresented = try await databaseService.transactionCount(accountId: accountId) > 1_000
            try await accountService.deleteAccount(account)
            if sidebarSelection.wrappedValue == accountId {
                sidebarSelection.wrappedValue = nil
            }
        } catch {
            printError("\(account.name): \(error)")
            deleteAccountError = error.localizedDescription
            deleteAccountErrorPresented = true
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
    var doneButton: some View {
        Button(.commonDone) {
            isListEditing = false
        }
        .fontWeight(.semibold)
    }

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
        if isPhone || isListEditing {
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
            usdValue: accountValue(account),
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
    func makeKeyStoreSection(_ keyStore: KeyStoreModel, accounts: [AccountModel]) -> some View {
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
            ForEach(accounts.sorted()) { account in
                makeAccountItem(account)
            }

            if isIOS, isListEditing {
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
            if !keyStore.isWatchOnly,
               !(expansionOverrides[keyStore.id] ?? !keyStore.isCollapsed),
               let value = totalValue(accounts) {
                Text("\(value.formattedAbbreviated()) US$")
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
                .style(isPhone ? .title : nil, foreground: isPhone ? .phoneLabel : .sidebarLabel)
        }
    }

    @MainActor
    func makeKeyStoreTitle(_ keyStore: KeyStoreModel) -> some View {
        HStack(spacing: isPhone || isListEditing ? 12 : 4) {
            if isIOS, isListEditing, !keyStore.isWatchOnly {
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
            Text(verbatim: title)
                .style(.title, foreground: .phoneLabel)
                .lineLimit(1)
                .truncationMode(.tail)
        } else if sidebarSelection.wrappedValue == keyStore.id {
            Text(verbatim: title)
                .contextMenu {
                    try? makeKeyStoreContextMenu(KeyStore(model: keyStore))
                }
                .onTapGesture {
                    editingName = keyStore.name
                    editingId = keyStore.id
                }
        } else {
            Text(verbatim: title)
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

    func accountValue(_ account: AccountModel) -> Decimal? {
#if os(macOS)
        accountValues[account.id]
#else
        account.usdValue()
#endif
    }

    func totalValue(_ accounts: [AccountModel]) -> Decimal? {
        var total: Decimal = 0
        for account in accounts {
            guard let value = accountValue(account) else {
                return nil
            }

            total += value
        }

        return total
    }

    func totalValueExcludingWatchOnlyAccounts() -> Decimal? {
        totalValue(allAccounts.filter { !$0.keyStore.isWatchOnly })
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
#if os(macOS)
    private func observeAccountValues() async {
        let entities = ["AccountModel", "BalanceModel", "StakingModel", "TokenModel"]
        await databaseService.modelContainer.observeSaves(affecting: Set(entities)) {
            let values = try await databaseService.modelContainer.readSnapshot { reader in
                try await reader.accountUSDValues()
            }

            try Task.checkCancellation()
            if values != accountValues {
                accountValues = values
            }
        }
    }
#endif

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

    func orderedKeyStores(accountsByKeyStore: [PersistentIdentifier: [AccountModel]]) -> [KeyStoreModel] {
        var result = hardwareKeyStores + localKeyStores

        if let watchOnlyKeyStore, !accountsByKeyStore[watchOnlyKeyStore.id, default: []].isEmpty {
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
