import BigInt
import SwiftUI
import WalletKit

struct ApprovalRevokeReview: Identifiable {
    let approvals: [TokenApproval]
    let id = UUID()
}

struct ApprovalRevokeSheet: View {
    let account: Account
    let isHardware: Bool
    let model: AccountApprovalsModel
    let review: ApprovalRevokeReview

    @Environment(\.dismiss) private var dismiss
    @State private var index = 0

    var body: some View {
        ApprovalRevokeStep(
            account: account,
            approval: review.approvals[index],
            isHardware: isHardware,
            model: model,
            stepTitle: review.approvals.count > 1
                ? String(localized: .approvalsRevokeProgress(index + 1, review.approvals.count))
                : nil
        ) {
            if index + 1 == review.approvals.count {
                dismiss()
            } else {
                index += 1
            }
        }
        .id(index)
    }
}

private struct ApprovalRevokeStep: View {
    let account: Account
    let approval: TokenApproval
    let isHardware: Bool
    let model: AccountApprovalsModel
    let stepTitle: String?
    let onSuccess: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var editedFees: Fees?
    @State private var errorMessage: String?
    @State private var estimateRevision = 0
    @State private var prepared: PreparedApprovalRevoke?
    @State private var progress: TransactionProgress?
    @State private var submissionFailed = false

    var body: some View {
        TransactionSheet(
            title: String(localized: .approvalsRevokeTitle),
            confirmTitle: String(localized: .approvalsRevokeConfirm),
            isConfirmEnabled: prepared != nil && editedFees != nil,
            isEstimateFeesEnabled: prepared != nil || errorMessage != nil,
            isProcessing: isSubmitting,
            onEstimateFees: isSubmitting || submissionFailed ? nil : refreshEstimate,
            onCancel: { dismiss() },
            onConfirm: confirm,
            parameters: { parameters },
            fees: { fees }
        )
        .hardwareKeyPromptHost(progress: progress?.prompt)
        .interactiveDismissDisabled(isSubmitting)
        .task(id: estimateRevision) {
            await estimate()
        }
    }

    private var parameters: some View {
        ParameterSection(stepTitle) {
            FromRow(account: account, title: String(localized: .commonFrom))
            ParameterRow(String(localized: .commonToken)) {
                tokenValue
            }

            ParameterRow(String(localized: .approvalsApprovedSpender), value: approval.spender)

            ParameterRow(
                String(localized: .approvalsNewAllowance),
                value: "\(0.formatted(.number)) \(approval.token.symbol)"
            )
        }
    }

    private var tokenValue: some View {
        #if os(macOS)
        let alignment: HorizontalAlignment = .leading
        #else
        let alignment: HorizontalAlignment = .trailing
        #endif

        return VStack(alignment: alignment, spacing: 2) {
            Text("\(approval.token.name) (\(approval.token.symbol))")
                #if os(macOS)
                .style(.medium, foreground: .primary)
                #endif
                .textSelection(.disabled)

            if let address = approval.token.address {
                Text(verbatim: address)
                    .style(.small, foreground: .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(address)
            }
        }
    }

    @ViewBuilder
    private var fees: some View {
        TransactionFeesView(
            blockchain: account.blockchain,
            estimatedFees: prepared?.fees,
            ethereumGasLimit: ethereumGasLimit,
            fees: $editedFees
        )
        .disabled(isSubmitting)

        if let errorMessage {
            ParameterSection(footer: errorMessage, footerColor: .red) {}
        }
    }

    private var ethereumGasLimit: BigUInt? {
        guard case let .ethereum(transaction) = prepared?.transaction else {
            return nil
        }

        return transaction.gasLimit
    }

    private var isSubmitting: Bool {
        progress != nil
    }

    private func confirm() {
        guard let prepared, let editedFees, !isSubmitting else {
            return
        }

        progress = .preparing
        Task {
            do {
                try await $progress.track {
                    if isHardware {
                        progress = .signing
                    }

                    try await model.submitRevoke(prepared, fees: editedFees) {
                        progress = .sending
                    }
                }

                onSuccess()
            } catch {
                self.prepared = nil
                submissionFailed = true
                errorMessage = String(
                    localized: .approvalsRevokeFailed(approval.token.symbol, error.localizedDescription)
                )
            }
        }
    }

    private func estimate() async {
        do {
            let quote = try await model.prepareRevoke(approval)
            try Task.checkCancellation()
            prepared = quote
        } catch {
            if !Task.isCancelled {
                errorMessage = String(localized: .approvalsRevokeEstimateFailed(error.localizedDescription))
            }
        }
    }

    private func refreshEstimate() {
        editedFees = nil
        prepared = nil
        errorMessage = nil
        estimateRevision += 1
    }
}
