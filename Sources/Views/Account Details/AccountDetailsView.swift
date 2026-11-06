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
    @State private var isFiltersPresented = false
    @State private var isTransactionSheetPresented = false
    @State private var searchText = ""
    @State private var staking: AccountStakingModel?
    @State private var summaryWidth: CGFloat = 0

    @State private var isSearchOpen = false

    @FocusState private var isSearchFocused: Bool
    @State private var selection: String?

    @AppStorage("AccountFilter") private var filterStorage = ""

    @SceneStorage("AccountDetailsTab") private var tabStorage = AccountTab.balances.rawValue

    @Namespace private var glassNamespace

    @Environment(\.sheetNamespace) private var sheetNamespace

    @Query var accountBalances: [BalanceModel]
    @Query var stakingRows: [StakingModel]
    @Query var allAccounts: [AccountModel]

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
        _stakingRows = Query(filter: #Predicate<StakingModel> { $0.account.id == accountId })
        _staking = State(initialValue: AccountStakingModel.make(account: account, keyStore: keyStore))
    }
}

// MARK: - View

extension AccountDetailsView: View {
    var body: some View {
        let selected = selectedBalance(in: cachedBalances)

        mainContent
        .navigationTitle(account.name)
        .toolbar {
            toolbarContent(selected)
        }

        // Balance refreshes update `BalanceModel` in place, so its persistent
        // identifier does not change when the on-chain amount changes, and price, identity and
        // image updates change only the token row. `refreshKey` covers all of them, so the cached
        // value list is rebuilt after every such change.
        .task(id: balanceRefreshId) {
            cachedBalances = accountBalances.compactMap { try? Balance(model: $0) }
        }

        // Resource patches change the row in place too; `revision` tells every applied write.
        .task(id: stakingRows.first?.revision) {
            staking?.apply(stakingRows.first.flatMap(Staking.init(model:)))
        }
        .task(id: tab == .staking) {
            if tab == .staking {
                await staking?.refresh()
            }
        }
        .sheet(isPresented: $isTransactionSheetPresented) {
            if let selected {
                TransferView(balance: selected)
                    .sheetZoom(from: Self.sendSourceId, namespace: sheetNamespace)
            }
        }
        .modifier(AccountStakingSheets(model: staking))
        #if os(iOS)
        .sheet(isPresented: $isFiltersPresented) {
            AccountFiltersView(tab: tab, filter: filter)
                .sheetZoom(from: Self.filtersSourceId, namespace: sheetNamespace)
        }
        #endif
    }

    @ViewBuilder
    private var mainContent: some View {
        #if os(macOS)
        VStack(alignment: .leading) {
            header(cachedBalances)
                .padding()

            TabView(selection: tabSelection) {
                AccountBalancesView(balances: cachedBalances, selection: $selection)
                    .tabItem {
                        Label(.accountDetailsTokenBalances, systemImage: "chart.bar")
                    }
                    .tag(AccountTab.balances)

                AccountTransactionsView(account)
                    .tabItem {
                        Label(.accountDetailsTransactions, systemImage: "list.bullet")
                    }
                    .tag(AccountTab.transactions)

                if account.blockchain.supportsApprovals {
                    AccountApprovalsView(account, canSign: canSign)
                        .tabItem {
                            Label(.accountDetailsApprovals, systemImage: "checkmark.shield")
                        }
                        .tag(AccountTab.approvals)
                }

                if let staking {
                    AccountStakingView(model: staking)
                        .tabItem {
                            Label(.accountDetailsStaking, systemImage: AccountTab.staking.systemImage)
                        }
                        .tag(AccountTab.staking)
                }
            }
        }
        #else
        scrollContent
            .simultaneousGesture(TapGesture().onEnded { isSearchFocused = false })
            .navigationBarTitleDisplayMode(.large)
            .safeAreaInset(edge: .bottom) {
                if tab != .staking {
                    bottomBar
                }
            }
        #endif
    }

    /// iPhone: one list scrolls the header, chips and rows together; pulling down refreshes.
    #if os(iOS)
    private var scrollContent: some View {
        List {
            // `navigationSubtitle` makes the large title open collapsed, so the header is a row.
            header(cachedBalances)
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                .listRowSeparator(.hidden)

            AccountTabChips(tabs: tabs, selection: tabSelection)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)

            content
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 0)
        .scrollDismissesKeyboard(.immediately)
        .refreshable {
            await refresh()
        }
    }
    #endif

    private func refresh() async {
        // Refreshes the staking position too.
        await AccountRefresh.run([account])
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .approvals:
            AccountApprovalsView(account, canSign: canSign, searchText: searchText)

        case .balances:
            AccountBalancesView(
                balances: visibleBalances,
                stakedUSDValue: stakingRows.first?.stakedUSDValue ?? 0,
                selection: $selection
            )

        case .staking:
            if let staking {
                AccountStakingView(model: staking)
            }

        case .transactions:
            AccountTransactionsView(
                account,
                filter: filterValue,
                myAddresses: Set(allAccounts.map { $0.address.lowercased() }),
                searchText: searchText
            )
        }
    }

    @MainActor
    @ToolbarContentBuilder
    private func toolbarContent(_ selected: Balance?) -> some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            // Watch-only accounts can't sign, so they get no transaction buttons at all.
            switch tab {
            case .staking where canSign:
                if let staking {
                    AccountStakingToolbarActions(model: staking)
                }

            case .balances where canSign:
                Button {
                    isSearchFocused = false
                    isTransactionSheetPresented = true
                } label: {
                    Label(.commonSend, systemImage: "paperplane")
                }
                .disabled(!canSend(selected))
                .sheetSource(Self.sendSourceId)
                .accessibilityIdentifier("account-send-button")
            case .approvals, .balances, .staking, .transactions:
                EmptyView()
            }
        }
    }

    #if os(iOS)
    /// Mail-style bottom bar: the filter button toggles the filter and, while on, grows into a pill
    /// that opens the sheet; the search field collapses to a button to make room.
    private var bottomBar: some View {
        let isActive = filterValue.isActive(in: tab)
        let isSearchExpanded = !isActive || tab == .approvals || isSearchOpen || !searchText.isEmpty

        return GlassBar {
            HStack(spacing: 0) {
                if tab != .approvals {
                    filterPill(isActive: isActive)
                        .glassCapsule(id: Self.filterGlassId, in: glassNamespace)
                        .padding(.trailing, 8)
                }

                searchField(isExpanded: isSearchExpanded)
                    // Squash and stretch measured from Mail. Scaling outside `glassEffect`
                    // leaves the content unscaled, so glass and content are pulsed separately.
                    .keyframeAnimator(initialValue: 0.0, trigger: tab != .approvals) { content, pulse in
                        content
                            .scaleEffect(x: 1 + 0.05 * pulse, y: 1 + 0.21 * pulse)
                            .padding(.horizontal, 9 * pulse)
                            .padding(.vertical, 5 * pulse)
                            .glassCapsule(id: Self.searchGlassId, in: glassNamespace)
                            .padding(.horizontal, -9 * pulse)
                            .padding(.vertical, -5 * pulse)
                    } keyframes: { _ in
                        CubicKeyframe(1, duration: 0.15)
                        CubicKeyframe(-0.17, duration: 0.25)
                        CubicKeyframe(0, duration: 0.2)
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .onTapGesture {
                        if !isSearchExpanded {
                            isSearchOpen = true
                        }
                    }
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
        .animation(.spring(duration: 0.3, bounce: 0.15), value: tab == .approvals)
        .animation(.smooth, value: isActive)
        .animation(.smooth, value: isSearchExpanded)
        .animation(.smooth, value: isSearchFocused)
        .animation(.smooth, value: summaryWidth)
        .onChange(of: isSearchFocused) {
            if !isSearchFocused, searchText.isEmpty {
                isSearchOpen = false
            }
        }
    }

    private func filterPill(isActive: Bool) -> some View {
        let isSummaryVisible = isActive && !isSearchFocused

        return HStack(spacing: 0) {
            Button {
                toggleFilter()
            } label: {
                Image(systemName: "line.3.horizontal.decrease")
                    .style(.large, foreground: isActive ? .white : .primary)
                    .frame(width: 40, height: 40)
                    .background(isActive ? Color.accentColor : .clear, in: .circle)
            }
            .accessibilityLabel(.accountDetailsFilters)
            .accessibilityIdentifier("account-filter-button")

            Button {
                isSearchFocused = false
                isFiltersPresented = true
            } label: {
                VStack(alignment: .leading, spacing: 0) {
                    Text(.accountDetailsFilteredBy)
                        .style(.smallHeader, foreground: .primary)

                    Text(filterValue.summary(in: tab))
                        .style(.small, foreground: .accentColor)
                        .lineLimit(1)
                }
                .fixedSize()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                    if width > 0 {
                        summaryWidth = width
                    }
                }
                .padding(.horizontal, 6)
                .frame(width: isSummaryVisible ? summaryWidth + 12 : 0, alignment: .leading)
                .opacity(isSummaryVisible ? 1 : 0)
                .clipped()
            }
            .buttonStyle(.plain)
            .disabled(!isSummaryVisible)
            .sheetSource(Self.filtersSourceId)
            .accessibilityIdentifier("account-filter-summary")
        }
        .padding(4)
    }

    private func searchField(isExpanded: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .style(.large, foreground: .primary)
                .frame(width: isExpanded ? 32 : 40, height: 40)
                .padding(.leading, isExpanded ? 6 : 0)

            if isExpanded {
                TextField(text: $searchText, prompt: Text(.accountDetailsSearch)) {
                    Text(.accountDetailsSearch)
                }
                .focused($isSearchFocused)
                .onAppear {
                    if isSearchOpen {
                        isSearchFocused = true
                    }
                }
                .submitLabel(.search)
                .accessibilityIdentifier("account-search-field")
            }
        }
        .padding(4)
        .frame(maxWidth: isExpanded ? .infinity : nil, alignment: .leading)
    }

    private func toggleFilter() {
        isSearchFocused = false

        var value = filterValue

        if value.isActive(in: tab) {
            value.reset(in: tab)
        } else {
            value.enableDefaults(in: tab)
        }

        filter.wrappedValue = value
    }
    #endif
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

    /// Address, chain details and native balance; the account name is the navigation title.
    func header(_ balances: [Balance]) -> some View {
        LazyVStack(alignment: .leading) {
            HStack {
                Text(displayAddress)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Image(systemName: "square.on.square")
                    .symbolEffect(.bounce, value: isCopyWalletAddressButtonActive)
                    .onTapGesture {
                        copyToClipboard(displayAddress)
                        isCopyWalletAddressButtonActive.toggle()
                    }
            }
            .style(isPhone ? .callout : .medium, foreground: .secondary)
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
            .lineLimit(1)
            .style(isPhone ? .caption : .small, foreground: .secondary)
            .padding(.bottom, 1)

            if let balance = balances.first(where: { $0.token.isNativeToken }) {
                Text("\(balance.decimalAmount.description) \(balance.token.symbol)")
                    .style(isPhone ? .caption : .small, foreground: .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    var balanceRefreshId: [String] {
        accountBalances.map(\.refreshKey)
    }

    static let filterGlassId = "filter"
    static let filtersSourceId = "account-filters"
    static let searchGlassId = "search"
    static let sendSourceId = "account-send"

    var filter: Binding<AccountFilter> {
        Binding(
            get: { AccountFilter(storageString: filterStorage) },
            set: { filterStorage = $0.storageString }
        )
    }

    var filterValue: AccountFilter {
        filter.wrappedValue
    }

    var tabs: [AccountTab] {
        var tabs: [AccountTab] = [.balances, .transactions]

        if account.blockchain.supportsApprovals {
            tabs.append(.approvals)
        }

        if account.blockchain.supportsStaking {
            tabs.append(.staking)
        }

        return tabs
    }

    var tab: AccountTab {
        let stored = AccountTab(rawValue: tabStorage) ?? .balances

        return tabs.contains(stored) ? stored : .balances
    }

    var tabSelection: Binding<AccountTab> {
        Binding(get: { tab }, set: { tabStorage = $0.rawValue })
    }

    /// Balances after the filter and search.
    var visibleBalances: [Balance] {
        let query = searchText.trimmingCharacters(in: .whitespaces)

        return cachedBalances.filter { balance in
            guard filterValue.includes(balance) else {
                return false
            }

            return query.isEmpty
                || balance.token.symbol.localizedCaseInsensitiveContains(query)
                || balance.token.name.localizedCaseInsensitiveContains(query)
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

    var canSign: Bool {
        keyStore.kind != .watchOnly
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
} // swiftlint:disable:this file_length
