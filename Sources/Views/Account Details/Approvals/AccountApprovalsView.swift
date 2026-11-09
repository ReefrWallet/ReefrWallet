//
//  AccountApprovalsView.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 24.10.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftData
import SwiftUI
import WalletKit

struct AccountApprovalsView: View {
    let account: Account
    /// Revoking signs, so watch-only accounts see the approvals without the means to select them.
    let canSign: Bool
    let searchText: String

    @State private var errorMessage: String?
    @State private var isRevoking = false
    @State private var isSelectingAll = false
    @State private var pages = AccountPages<TokenApproval>()
    @State private var selection: Set<TokenApproval.ID> = []

    private let databaseService = DI.injectOrFail(DatabaseService.self)
    private let service = DI.injectOrFail(ApprovalService.self)

    init(_ account: Account, canSign: Bool, searchText: String = "") {
        self.account = account
        self.canSign = canSign
        self.searchText = searchText
    }

    var body: some View {
        let approvals = pages.rows.filter { $0.matches(searchText) }

        #if os(iOS)
        alerting(AccountCountLabel(text: String(localized: .approvalsApprovalCount(approvals.count))))
            .task { await observeApprovals() }
            .task(id: isSearching && pages.isLoaded) {
                if isSearching, pages.isLoaded {
                    await loadRemaining()
                }
            }
            .task(id: isSelectingAll) {
                if isSelectingAll {
                    await selectAll()
                }
            }
            .onChange(of: searchText) {
                isSelectingAll = false
            }

        if !service.supports(account) {
            AccountEmptyRow(title: .approvalsNeedsEtherscanKey)
        } else if !pages.isLoaded || (approvals.isEmpty && isSearching && pages.hasMore) {
            ProgressView()
        } else if pages.rows.isEmpty {
            AccountEmptyRow(title: .approvalsNoApprovals)
                .accessibilityIdentifier("account-no-approvals")
        } else {
            ForEach(approvals) { approval in
                row(approval)
                    .onAppear { loadMore(near: approval.id) }
            }

            if canSign {
                actions(approvals)
                    .listRowSeparator(.hidden)
            }
        }
        #else
        alerting(
            VStack {
                Text(.approvalsApprovalCount(approvals.count))
                    .style(.mediumHeader, foreground: .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)

                content(approvals)

                if canSign {
                    actions(approvals)
                        .padding([.bottom, .horizontal])
                }
            }
        )
        .task { await observeApprovals() }
        .task(id: isSelectingAll) {
            if isSelectingAll {
                await selectAll()
            }
        }
        #endif
    }
}

// MARK: - Subviews

private extension AccountApprovalsView {
    var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func fetchPage(offset: Int, limit: Int) async throws -> AccountPage<TokenApproval> {
        let account = account
        return try await databaseService.modelContainer.readSnapshot { reader in
            try await reader.fetchApprovalPage(account: account, offset: offset, limit: limit)
        }
    }

    func loadMore(near id: TokenApproval.ID) {
        pages.requestNext(near: id, using: fetchPage)
    }

    func loadRemaining() async {
        do {
            try await pages.loadRemaining(using: fetchPage)
        } catch is CancellationError {
            return
        } catch {
            printError(error)
        }
    }

    func observeApprovals() async {
        await databaseService.modelContainer.observeSaves(affecting: ["ApprovalModel", "TokenModel"]) {
            try await pages.refresh(using: fetchPage)
        }
    }

    func alerting(_ view: some View) -> some View {
        view.alert(
            .accountDetailsApprovals,
            isPresented: Binding(get: { errorMessage != nil }, set: { _ in errorMessage = nil }),
            presenting: errorMessage
        ) { _ in
            Button(.commonOk) {}
        } message: { message in
            Text(message)
        }
    }

    /// Search can hide a selected approval, so only the listed ones are counted or revoked.
    func actions(_ approvals: [TokenApproval]) -> some View {
        let selectedCount = approvals.count { selection.contains($0.id) }

        return HStack {
            Toggle(.approvalsSelectAll, isOn: allSelected(approvals))
                .disabled(approvals.isEmpty || isSelectingAll)

            Spacer()

            Button(.approvalsRevokeSelected(selectedCount)) {
                Task {
                    await revokeSelected(approvals)
                }
            }
            .disabled(selectedCount == 0 || isRevoking || isSelectingAll)
            .accessibilityIdentifier("approvals-revoke-selected-button")
        }
    }

    func row(_ approval: TokenApproval) -> some View {
        HStack(spacing: 12) {
            if canSign {
                Toggle("", isOn: selectionBinding(approval.id))
                    .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(approval.token.symbol)
                    .style(.headline, foreground: .primary)

                Text(approval.spender.shortened(prefix: 8, suffix: 6))
                    .style(.mono, foreground: .secondary)
            }

            Spacer()

            Text(
                approval.isUnlimited ? String(localized: .approvalsUnlimited) : Self.amountText(
                    approval.allowance,
                    approval.token
                )
            )
                .style(.large, foreground: approval.isUnlimited ? .red : .primary)
        }
    }

    @ViewBuilder
    func content(_ approvals: [TokenApproval]) -> some View {
        if !service.supports(account) {
            EmptyStateView(.approvalsNeedsEtherscanKey)
        } else if !pages.isLoaded {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if approvals.isEmpty {
            EmptyStateView(.approvalsNoApprovals)
                .accessibilityIdentifier("account-no-approvals")
        } else {
            table(approvals)
        }
    }

    func table(_ approvals: [TokenApproval]) -> some View {
        Table(approvals) {
            if canSign {
                TableColumn("") { approval in
                    Toggle("", isOn: selectionBinding(approval.id))
                        .labelsHidden()
                }
                .width(28)
            }

            TableColumn(.approvalsAsset) { approval in
                Text(approval.token.name)
                    .style(.medium, foreground: .primary)
                    .help(approval.token.address ?? "")
                    .onAppear { loadMore(near: approval.id) }
            }
            .width(min: 90, ideal: 150)

            TableColumn(.commonType) { _ in
                Text(.commonToken)
                    .style(.medium, foreground: .primary)
            }
            .width(min: 60, ideal: 80)

            TableColumn(.approvalsApprovedAmount) { approval in
                Text(
                    approval.isUnlimited ? String(localized: .approvalsUnlimited) : Self.amountText(
                        approval.allowance,
                        approval.token
                    )
                )
                    .style(.medium, foreground: approval.isUnlimited ? .red : .primary)
            }
            .width(min: 100, ideal: 140)

            TableColumn(.approvalsApprovedSpender) { approval in
                Text(approval.spender.shortened(prefix: 8, suffix: 6))
                    .style(.mono, foreground: .secondary)
                    .help(approval.spender)
            }
            .width(min: 120, ideal: 180)

            TableColumn(.approvalsMyApprovalTime) { approval in
                Text(approval.approvedAt.map(Self.timeText) ?? "—")
                    .style(.medium, foreground: .secondary)
                    .help(approval.approvedAt?.formatted(date: .complete, time: .standard) ?? "")
            }
            .width(min: 90, ideal: 130)
        }
    }
}

// MARK: - Logic

private extension AccountApprovalsView {
    static func amountText(_ amount: BigUInt, _ token: Token) -> String {
        let value = Decimal(sign: .plus, exponent: -Int(token.decimalsCount), significand: Decimal(amount))
        return value.formatted(.number.precision(.fractionLength(0...4)))
    }

    static func timeText(_ date: Date) -> String {
        date.formatted(.relative(presentation: .numeric, unitsStyle: .wide))
    }

    func allSelected(_ approvals: [TokenApproval]) -> Binding<Bool> {
        Binding(
            get: { !pages.hasMore && !approvals.isEmpty && approvals.allSatisfy { selection.contains($0.id) } },
            set: { isOn in
                if isOn {
                    isSelectingAll = true
                } else {
                    selection.subtract(approvals.map(\.id))
                }
            }
        )
    }

    func selectAll() async {
        defer {
            isSelectingAll = false
        }

        do {
            try await pages.loadRemaining(using: fetchPage)
            try Task.checkCancellation()
            selection.formUnion(pages.rows.filter { $0.matches(searchText) }.map(\.id))
        } catch is CancellationError {
            return
        } catch {
            printError(error)
        }
    }

    func selectionBinding(_ id: TokenApproval.ID) -> Binding<Bool> {
        Binding(
            get: { selection.contains(id) },
            set: { isOn in
                if isOn {
                    selection.insert(id)
                } else {
                    selection.remove(id)
                }
            }
        )
    }

    /// Sequential: each revoke is its own signature (and hardware prompt).
    /// Stops at the first failure; broadcast revokes leave the list.
    func revokeSelected(_ approvals: [TokenApproval]) async {
        isRevoking = true
        defer {
            isRevoking = false
        }

        for approval in approvals where selection.contains(approval.id) {
            do {
                _ = try await service.revoke(approval, account: account)
                selection.remove(approval.id)
            } catch {
                errorMessage = String(
                    localized: .approvalsRevokeFailed(approval.token.symbol, error.localizedDescription)
                )

                return
            }
        }
    }
}
