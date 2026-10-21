//
//  DappRequestSheet.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 25.09.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI
import WalletKit

/// The approval prompt for a ``DappApprovalRequest``. Sign requests use the
/// shared ``TransactionSheet`` with the chain's parameters and fees views
/// (ADR-042); connect requests keep their own short layout.
struct DappRequestSheet: View {
    let request: DappApprovalRequest
    /// Whether the request was approved and is being handled.
    var isProcessing = false
    /// The user's decision, and whether to keep the sheet up while it runs.
    let onResolve: (DappApprovalResult, Bool) -> Void

    @State private var editedFees: Fees?
    @State private var feeEstimationTask: Task<Void, Never>?
    @State private var isHardwareAccount = false
    /// Ethereum fees re-fetched with Estimate Fees, replacing the request's.
    @State private var reestimatedFees: Fees?

    private let databaseService = DI.injectOrFail(DatabaseService.self)

    var body: some View {
        Group {
            switch request {
            case .connect:
                connectSheet
            case let .signMessage(_, _, account, preview):
                messageSheet(account: account, preview: preview)
            case let .sendTransaction(_, _, account, preview):
                transactionSheet(account: account, preview: preview)
            }
        }
        .interactiveDismissDisabled(isProcessing)
        .task {
            isHardwareAccount = (try? await databaseService.fetchKeyStore(id: account.keyStoreId))?.isHardware ?? false
        }
    }
}

// MARK: - Subviews

private extension DappRequestSheet {
    var connectSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect")
                .style(.largeHeader)
                .accessibilityIdentifier("dapp-request-title")

            ParameterSection {
                websiteRow
                FromRow(account: account, title: "Account")
            }

            Text("This site is requesting to connect to this account.")
                .style(.medium)

            Spacer()

            if isProcessing {
                HStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)

                    Text("Signing...")
                        .style(.medium, foreground: .secondary)
                }
            } else {
                connectButtons
            }
        }
        .padding()
        .frame(minWidth: 380, minHeight: 240)
    }

    var connectButtons: some View {
        HStack {
            Spacer()
            Button("Reject") {
                onResolve(.rejected, false)
            }
            .accessibilityIdentifier("dapp-reject-button")

            Button("Approve") {
                onResolve(.approved, isHardwareAccount)
            }
            .accessibilityIdentifier("dapp-approve-button")
        }
    }

    @ViewBuilder
    func messageSheet(account: Account, preview: DappMessagePreview) -> some View {
        let isTypedData = if case .ethereumTypedData = preview { true } else { false }

        signSheet(title: isTypedData ? "Sign Typed Data" : "Sign Message") {
            switch preview {
            case let .aptosMessage(fullMessage):
                SignMessageParametersView(account: account, message: fullMessage)
            case let .ethereumPersonal(message):
                SignMessageParametersView(account: account, message: message)
            case let .ethereumTypedData(summary):
                EthereumTypedDataParametersView(account: account, summary: summary)
            case let .solanaMessage(message):
                SignMessageParametersView(account: account, message: message)
            case let .suiPersonal(message):
                SignMessageParametersView(account: account, message: message)
            case let .tronMessage(message):
                SignMessageParametersView(account: account, message: message)
            }
        } fees: {
            EmptyView()
        }
    }

    func signSheet<Parameters: View, Fees: View>(
        title: String,
        isConfirmEnabled: Bool = true,
        onEstimateFees: (() -> Void)? = nil,
        @ViewBuilder parameters: () -> Parameters,
        @ViewBuilder fees: () -> Fees
    ) -> some View {
        TransactionSheet(
            title: title,
            confirmTitle: "Confirm",
            isConfirmEnabled: isConfirmEnabled,
            isProcessing: isProcessing,
            onEstimateFees: onEstimateFees,
            onCancel: { onResolve(.rejected, false) },
            onConfirm: { onResolve(approvedResult, isHardwareAccount) },
            accessibilityIds: .init(
                cancel: "dapp-reject-button",
                confirm: "dapp-approve-button",
                title: "dapp-request-title"
            ),
            parameters: {
                // Not in Penpot: the user should see who is asking.
                ParameterSection {
                    websiteRow
                }

                parameters()
            },
            fees: fees
        )
    }

    @ViewBuilder
    func transactionSheet(account: Account, preview: DappTransactionPreview) -> some View {
        if case let .ethereum(call, _) = preview {
            signSheet(
                title: "Sign Transaction",
                isConfirmEnabled: editedFees != nil,
                onEstimateFees: onEstimateEthereumFees
            ) {
                EthereumTransactionParametersView(account: account, call: call)
            } fees: {
                TransactionFeesView(
                    blockchain: account.blockchain,
                    estimatedFees: reestimatedFees ?? preview.fees,
                    // Not in Penpot: the user should know the site picked these values.
                    warning: call.hasDappFeeOverrides && reestimatedFees == nil
                        ? "Gas limit or fees were set by the site."
                        : nil,
                    fees: $editedFees
                )
            }
        } else {
            signSheet(title: "Sign Transaction") {
                switch preview {
                case let .aptos(preview):
                    AptosTransactionParametersView(account: account, preview: preview)
                case .ethereum:
                    EmptyView()
                case let .solana(preview):
                    SolanaTransactionParametersView(account: account, preview: preview)
                case let .sui(preview):
                    SuiTransactionParametersView(account: account, preview: preview)
                case let .tron(preview):
                    TronTransactionParametersView(account: account, preview: preview)
                }
            } fees: {
                TransactionFeesView(
                    blockchain: account.blockchain,
                    estimatedFees: preview.fees,
                    isEditable: false,
                    fees: .constant(nil)
                )
            }
        }
    }

    var websiteRow: some View {
        ParameterRow("Website", value: origin)
    }
}

// MARK: - Callbacks

private extension DappRequestSheet {
    /// Re-fetches fee rates for the request's gas limit. Ethereum only: the
    /// other chains' fees are fixed by the dapp (ADR-042).
    func onEstimateEthereumFees() {
        guard case let .sendTransaction(_, _, account, .ethereum(call, _)) = request else {
            return
        }

        feeEstimationTask?.cancel()
        feeEstimationTask = Task {
            do {
                let service = DI.injectOrFail(FeeEstimationService.self)
                let estimate = try await service.estimateCall(
                    to: try call.to.map { try EthereumAddress(string: $0) },
                    value: call.value,
                    data: call.data,
                    gasLimit: call.gasLimit,
                    account: account
                )

                guard !Task.isCancelled else {
                    return
                }

                reestimatedFees = service.ethereumFees(
                    rates: estimate.rates,
                    gasLimit: call.gasLimit,
                    maxFee: estimate.rates.maxFeePerGas,
                    maxPriorityFee: estimate.rates.maxPriorityFeePerGas
                )
            } catch {
                printError(error)
            }
        }
    }
}

// MARK: - Logic

private extension DappRequestSheet {
    var account: Account {
        switch request {
        case let .connect(_, _, account): account
        case let .signMessage(_, _, account, _): account
        case let .sendTransaction(_, _, account, _): account
        }
    }

    /// `.approvedWithFees` for an Ethereum transaction (carrying any fee
    /// edits the user made), `.approved` for every other request kind.
    var approvedResult: DappApprovalResult {
        guard case let .sendTransaction(_, _, _, .ethereum(_, estimatedFees)) = request else {
            return .approved
        }

        return .approvedWithFees(editedFees ?? reestimatedFees ?? estimatedFees)
    }

    /// The origin the request actually came from — carried on the
    /// request itself (from `WKSecurityOrigin`) rather than read from
    /// the browser's current URL, so a redirect or a stale tab can't
    /// make this sheet display a different origin than the one the
    /// dapp is being approved for.
    var origin: String {
        switch request {
        case let .connect(origin, _, _): origin
        case let .signMessage(origin, _, _, _): origin
        case let .sendTransaction(origin, _, _, _): origin
        }
    }
}
