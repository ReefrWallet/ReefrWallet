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

    @State private var errorMessage: String?
    @State private var isRevoking = false
    @State private var selection: Set<TokenApproval.ID> = []

    @Query private var approvalModels: [ApprovalModel]
    @Query private var balanceModels: [BalanceModel]

    private let service = DI.injectOrFail(ApprovalService.self)

    init(_ account: Account) {
        guard let accountId = account.id else {
            preconditionFailure()
        }

        self.account = account

        let approvalSort = [SortDescriptor(\ApprovalModel.approvedAt, order: .reverse)]

        _approvalModels = Query(filter: #Predicate<ApprovalModel> { $0.account.id == accountId }, sort: approvalSort)
        _balanceModels = Query(filter: #Predicate<BalanceModel> { $0.account.id == accountId })
    }

    var body: some View {
        let approvals = approvalModels.map(TokenApproval.init(model:))

        VStack {
            Text("\(approvals.count) Approvals")
                .style(.mediumHeader, foreground: .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)

            content(approvals)

            HStack {
                Toggle("Select All", isOn: allSelected(approvals))
                    .disabled(approvals.isEmpty)

                Spacer()

                Button("Revoke Selected (\(selection.count))") {
                    Task {
                        await revokeSelected(approvals)
                    }
                }
                .disabled(selection.isEmpty || isRevoking)
                .accessibilityIdentifier("approvals-revoke-selected-button")
            }
            .padding([.bottom, .horizontal])
        }
        .alert(
            "Approvals",
            isPresented: Binding(get: { errorMessage != nil }, set: { _ in errorMessage = nil }),
            presenting: errorMessage
        ) { _ in
            Button("OK") {}
        } message: { message in
            Text(message)
        }
    }
}

// MARK: - Subviews

private extension AccountApprovalsView {
    @ViewBuilder
    func content(_ approvals: [TokenApproval]) -> some View {
        if !service.supports(account) {
            EmptyStateView("Approvals need an Etherscan API key and a supported chain")
        } else if approvals.isEmpty {
            EmptyStateView("No Approvals")
                .accessibilityIdentifier("account-no-approvals")
        } else {
            table(approvals)
        }
    }

    func table(_ approvals: [TokenApproval]) -> some View {
        Table(approvals) {
            TableColumn("") { approval in
                Toggle("", isOn: selectionBinding(approval.id))
                    .labelsHidden()
            }
            .width(28)

            TableColumn("Asset") { approval in
                HStack {
                    Text(approval.token.symbol)
                        .style(.medium, foreground: .primary)

                    if let balance = balance(of: approval.token) {
                        Text(balance)
                            .style(.medium, foreground: .secondary)
                    }
                }
                .help(approval.token.address ?? "")
            }
            .width(min: 90, ideal: 150)

            TableColumn("Type") { _ in
                Text("Token")
                    .style(.medium, foreground: .primary)
            }
            .width(min: 60, ideal: 80)

            TableColumn("Approved Amount") { approval in
                Text(approval.isUnlimited ? "Unlimited" : Self.amountText(approval.allowance, approval.token))
                    .style(.medium, foreground: approval.isUnlimited ? .red : .primary)
            }
            .width(min: 100, ideal: 140)

            TableColumn("Approved Spender") { approval in
                Text(approval.spender.shortened(prefix: 8, suffix: 6))
                    .style(.mono, foreground: .secondary)
                    .help(approval.spender)
            }
            .width(min: 120, ideal: 180)

            TableColumn("My Approval Time") { approval in
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
            get: { !approvals.isEmpty && selection.count == approvals.count },
            set: { selection = $0 ? Set(approvals.map(\.id)) : [] }
        )
    }

    /// The account's held amount of `token`, if it has a stored balance.
    func balance(of token: Token) -> String? {
        balanceModels
            .first { $0.token.address == token.address }
            .map { Self.amountText($0.amount, token) }
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
                errorMessage = "Revoking \(approval.token.symbol) failed: \(error.localizedDescription)"
                return
            }
        }
    }
}
