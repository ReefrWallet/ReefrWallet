//
//  AccountTransactionsView.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 17.09.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftData
import SwiftUI

struct AccountTransactionsView: View {
    let account: Account
    var filter = AccountFilter()
    var myAddresses: Set<String> = []
    var searchText = ""

    @State private var pages = AccountPages<TransactionRowModel>()
    @State private var totalTransactionCount: Int?

    private let databaseService = DI.injectOrFail(DatabaseService.self)

    init(
        _ account: Account,
        filter: AccountFilter = AccountFilter(),
        myAddresses: Set<String> = [],
        searchText: String = ""
    ) {
        self.account = account
        self.filter = filter
        self.myAddresses = myAddresses
        self.searchText = searchText
    }

    var body: some View {
        let visibleRows = filteredRows

        #if os(iOS)
        AccountCountLabel(text: transactionCountText)
            .accessibilityIdentifier("account-transactions-count")
            .accessibilityHidden(totalTransactionCount == nil)
            .task { await observeTransactions() }
            .task(id: isSearching && pages.isLoaded) {
                if isSearching, pages.isLoaded {
                    await loadRemaining()
                }
            }

        if visibleRows.isEmpty, !pages.isLoaded || (isSearching && pages.hasMore) {
            ProgressView()
        } else if pages.rows.isEmpty {
            AccountEmptyRow(title: .transactionsNoTransactions)
                .accessibilityIdentifier("account-no-transactions")
        } else {
            ForEach(visibleRows) { model in
                TransactionRow(model: model)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    .onAppear { loadMore(near: model.id) }
            }
        }
        #else
        VStack {
            Text(transactionCountText)
                .accessibilityIdentifier("account-transactions-count")
                .accessibilityHidden(totalTransactionCount == nil)
                .style(.mediumHeader, foreground: .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading)

            if !pages.isLoaded {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if pages.rows.isEmpty {
                EmptyStateView(.transactionsNoTransactions)
                    .accessibilityIdentifier("account-no-transactions")
            } else {
                TransactionsTable(rows: visibleRows, schema: presenter.schema, onRowAppear: loadMore)
            }
        }
        .task { await observeTransactions() }
        #endif
    }

    private func fetchPage(offset: Int, limit: Int) async throws -> AccountPage<TransactionRowModel> {
        let account = account
        return try await databaseService.modelContainer.readSnapshot { reader in
            try await reader.transactionRows(for: account, offset: offset, limit: limit)
        }
    }

    private var filteredRows: [TransactionRowModel] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty || filter.restrictsTransactions else {
            return pages.rows
        }

        return pages.rows.filter { model in
            guard filter.includes(model, myAddresses: myAddresses) else {
                return false
            }

            return query.isEmpty
                || model.title.localizedCaseInsensitiveContains(query)
                || model.subtitle.localizedCaseInsensitiveContains(query)
                || model.identifier.localizedCaseInsensitiveContains(query)
                || (model.method?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private var isSearching: Bool {
        filter.restrictsTransactions || !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var transactionCountText: String {
        totalTransactionCount.map { String(localized: .transactionsTransactionCount($0)) } ?? ""
    }

    private func loadMore(near id: TransactionRowModel.ID) {
        pages.requestNext(near: id, using: fetchPage)
    }

    private func loadRemaining() async {
        do {
            try await pages.loadRemaining(using: fetchPage)
        } catch is CancellationError {
            return
        } catch {
            printError(error)
        }
    }

    private func observeTransactions() async {
        guard let accountId = account.id else {
            return
        }

        let container = databaseService.modelContainer
        await container.observeSaves(affecting: [
            "WalletTransactionModel", "WalletTransactionEffectModel"
        ]) {
            totalTransactionCount = try await container.readSnapshot { reader in
                try await reader.transactionCount(accountId: accountId)
            }

            try await pages.refresh(using: fetchPage)
        }
    }

    private var presenter: any TransactionRowPresenter {
        TransactionRowPresenters.presenter(for: account.blockchain)
    }
}

private extension DatabaseService {
    func transactionRows(for account: Account, offset: Int, limit: Int) throws -> AccountPage<TransactionRowModel> {
        guard let id = account.id else {
            throw ReefrError.invalidData
        }

        try Task.checkCancellation()
        let presenter = TransactionRowPresenters.presenter(for: account.blockchain)
        let page = try fetchTransactionPage(accountId: id, offset: offset, limit: limit)
        return AccountPage(
            rows: page.rows.map { presenter.makeRowModel($0, account: account) },
            hasMore: page.hasMore
        )
    }
}

@MainActor
@Observable
final class AccountPages<Row: Equatable & Identifiable & Sendable> {
    typealias Fetch = (_ offset: Int, _ limit: Int) async throws -> AccountPage<Row>

    private let batchSize = 40

    private(set) var rows: [Row] = []
    private(set) var hasMore = true
    private(set) var isLoaded = false

    @ObservationIgnored private var offset = 0
    @ObservationIgnored private var isLoading = false
    @ObservationIgnored private var requestedOffset: Int?
    @ObservationIgnored private var rowIds: Set<Row.ID> = []

    func requestNext(near id: Row.ID, using fetch: @escaping Fetch) {
        guard hasMore, rows.suffix(8).contains(where: { $0.id == id }) else {
            return
        }

        Task {
            await loadNext(using: fetch)
        }
    }

    func loadNext(using fetch: Fetch) async {
        if isLoading {
            requestedOffset = offset
            return
        }

        do {
            try await appendPage(using: fetch)
        } catch is CancellationError {
            return
        } catch {
            printError(error)
        }
    }

    func loadRemaining(using fetch: Fetch) async throws {
        while isLoaded, hasMore {
            try Task.checkCancellation()
            try await appendPage(using: fetch)
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    func refresh(using fetch: Fetch) async throws {
        while isLoading {
            try await Task.sleep(for: .milliseconds(50))
        }

        let needsPrefetch = !isLoaded
        try await refreshLoadedPages(using: fetch)
        let reachedEndWhileRefreshing = requestedOffset == offset
        requestedOffset = nil
        if reachedEndWhileRefreshing {
            try await appendPage(using: fetch)
        } else if needsPrefetch, hasMore, offset == batchSize {
            try await Task.sleep(for: .milliseconds(150))
            if offset == batchSize {
                try await appendPage(using: fetch)
            }
        }
    }

    private func appendPage(using fetch: Fetch) async throws {
        guard isLoaded, hasMore, !isLoading else {
            return
        }

        isLoading = true
        defer {
            isLoading = false
        }

        let page = try await fetch(offset, batchSize)
        try Task.checkCancellation()
        let newRows = page.rows.filter { rowIds.insert($0.id).inserted }
        rows.append(contentsOf: newRows)
        offset += batchSize
        hasMore = page.hasMore
    }

    private func refreshLoadedPages(using fetch: Fetch) async throws {
        isLoading = true
        defer {
            isLoading = false
        }

        var updated: [Row] = []
        var seen: Set<Row.ID> = []
        var consumed = 0
        var more = true
        repeat {
            try Task.checkCancellation()
            let page = try await fetch(consumed, batchSize)
            updated += page.rows.filter { seen.insert($0.id).inserted }
            consumed += batchSize
            more = page.hasMore
        } while more && consumed < offset

        try Task.checkCancellation()
        if rows != updated {
            rows = updated
        }

        rowIds = seen
        offset = consumed
        hasMore = more
        isLoaded = true
    }
}
