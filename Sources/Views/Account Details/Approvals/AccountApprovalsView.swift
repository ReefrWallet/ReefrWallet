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
    @Bindable var model: AccountApprovalsModel

    let canSign: Bool
    var searchText = ""

    var body: some View {
        let approvals = model.visibleApprovals(matching: searchText)
        let countText = model.countText(visible: approvals.count, isSearching: !searchText.isEmpty)

        #if os(iOS)
        let showsCount = model.pages.isLoaded

        AccountCountLabel(text: showsCount ? countText : "")
            .accessibilityHidden(!showsCount)
            .task { await model.observeApprovals() }
            .task(id: isSearching && model.pages.isLoaded) {
                if isSearching, model.pages.isLoaded {
                    await model.loadRemaining()
                }
            }

        if !model.isSupported {
            AccountEmptyRow(title: .approvalsNeedsEtherscanKey)
        } else if !approvals.isEmpty {
            ForEach(approvals) { approval in
                row(approval)
                    .onAppear { model.loadMore(near: approval.id) }
            }
        } else if model.pages.isLoaded, model.pages.rows.isEmpty {
            AccountEmptyRow(title: .approvalsNoApprovals)
                .accessibilityIdentifier("account-no-approvals")
        }
        #else
        content(approvals)
            .statusBar(edge: .top) {
                Text(verbatim: countText)
                    .style(.mediumHeader, foreground: .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }
            .task { await model.observeApprovals() }
        #endif
    }
}

private extension AccountApprovalsView {
    #if os(iOS)
    var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    @ViewBuilder
    func row(_ approval: TokenApproval) -> some View {
        if canSign {
            let isSelected = model.selection.contains(approval.id)

            Button {
                if isSelected {
                    model.selection.remove(approval.id)
                } else {
                    model.selection.insert(approval.id)
                }
            } label: {
                rowContent(approval)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .listRowBackground(isSelected ? Color.accentColor.opacity(0.18) : nil)
        } else {
            rowContent(approval)
        }
    }

    func rowContent(_ approval: TokenApproval) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: approval.token.symbol)
                .style(.headline, foreground: .primary)

            Text(verbatim: approval.spender.shortened(prefix: 8, suffix: 6))
                .style(.mono, foreground: .secondary)

            LabeledContent {
                Text(verbatim: allowanceText(approval))
                    .style(.callout, foreground: approval.isUnlimited ? .red : .primary)
            } label: {
                Text(.approvalsApprovedAmount)
                    .style(.callout, foreground: .secondary)
            }

            LabeledContent {
                Text(verbatim: approvedAtText(approval))
                    .style(.callout, foreground: .primary)
            } label: {
                Text(.approvalsMyApprovalTime)
                    .style(.callout, foreground: .secondary)
            }
        }
    }
    #else
    @ViewBuilder
    func content(_ approvals: [TokenApproval]) -> some View {
        if !model.isSupported {
            EmptyStateView(.approvalsNeedsEtherscanKey)
        } else if !model.pages.isLoaded {
            Color.clear
        } else if approvals.isEmpty {
            EmptyStateView(.approvalsNoApprovals)
                .accessibilityIdentifier("account-no-approvals")
        } else if canSign {
            Table(approvals, selection: $model.selection) { approvalColumns }
        } else {
            Table(approvals) { approvalColumns }
        }
    }

    @TableColumnBuilder<TokenApproval, Never>
    var approvalColumns: some TableColumnContent<TokenApproval, Never> {
        TableColumn(.approvalsAsset) { approval in
            Text(verbatim: approval.token.name)
                .style(.medium, foreground: .primary)
                .help(approval.token.address ?? "")
                .onAppear { model.loadMore(near: approval.id) }
        }
        .width(min: 90, ideal: 150)

        TableColumn(.approvalsApprovedAmount) { approval in
            Text(verbatim: allowanceText(approval))
                .style(.medium, foreground: approval.isUnlimited ? .red : .primary)
        }
        .width(min: 100, ideal: 140)

        TableColumn(.approvalsApprovedSpender) { approval in
            Text(verbatim: approval.spender.shortened(prefix: 8, suffix: 6))
                .style(.mono, foreground: .secondary)
                .help(approval.spender)
        }
        .width(min: 120, ideal: 180)

        TableColumn(.approvalsMyApprovalTime) { approval in
            Text(verbatim: approvedAtText(approval))
                .style(.medium, foreground: .secondary)
                .help(approval.approvedAt?.formatted(date: .complete, time: .standard) ?? "")
        }
        .width(min: 90, ideal: 130)
    }
    #endif

    func allowanceText(_ approval: TokenApproval) -> String {
        if approval.isUnlimited {
            return String(localized: .approvalsUnlimited)
        }

        let value = Decimal(
            sign: .plus,
            exponent: -Int(approval.token.decimalsCount),
            significand: Decimal(approval.allowance)
        )

        return value.formatted(.number.precision(.fractionLength(0...4)))
    }

    func approvedAtText(_ approval: TokenApproval) -> String {
        approval.approvedAt?.formatted(.relative(presentation: .numeric, unitsStyle: .wide)) ?? "—"
    }
}

@MainActor
@Observable
final class AccountApprovalsModel {
    var selection: Set<TokenApproval.ID> = []
    private(set) var totalCount: Int?

    let pages = AccountPages<TokenApproval>()

    private let account: Account
    private let databaseService = DI.injectOrFail(DatabaseService.self)

    init(_ account: Account) {
        self.account = account
    }

    var isSupported: Bool {
        switch account.blockchain {
        case .evm:
            DI.injectOrFail(EthereumApprovalService.self).supports(account)
        case .tron:
            true
        default:
            false
        }
    }

    /// The stored total, not just the loaded pages; a search shows the matches found so far.
    func countText(visible: Int, isSearching: Bool) -> String {
        String(localized: .approvalsApprovalCount(isSearching ? visible : totalCount ?? visible))
    }

    func visibleApprovals(matching searchText: String) -> [TokenApproval] {
        pages.rows.filter { $0.matches(searchText) }
    }

    private func fetchPage(offset: Int, limit: Int) async throws -> AccountPage<TokenApproval> {
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
        let account = account
        let container = databaseService.modelContainer

        await container.observeSaves(affecting: ["ApprovalModel", "TokenModel"]) {
            totalCount = try await container.readSnapshot { reader in
                try await reader.approvalCount(account: account)
            }

            try await pages.refresh(using: fetchPage)
        }
    }

    func prepareRevoke(_ approval: TokenApproval) async throws -> PreparedApprovalRevoke {
        switch account.blockchain {
        case .evm:
            try await DI.injectOrFail(EthereumApprovalService.self).prepareRevoke(approval, account: account)
        case .tron:
            try await DI.injectOrFail(TronApprovalService.self).prepareRevoke(approval, account: account)
        default:
            throw ReefrError.notSupported
        }
    }

    func submitRevoke(
        _ prepared: PreparedApprovalRevoke,
        fees: Fees,
        onSending: @MainActor @Sendable () -> Void
    ) async throws {
        switch prepared.transaction {
        case .ethereum:
            try await DI.injectOrFail(EthereumApprovalService.self)
                .submitRevoke(prepared, account: account, fees: fees, onSending: onSending)
        case .tron:
            try await DI.injectOrFail(TronApprovalService.self)
                .submitRevoke(prepared, account: account, fees: fees, onSending: onSending)
        }

        selection.remove(prepared.approval.id)
    }
}
