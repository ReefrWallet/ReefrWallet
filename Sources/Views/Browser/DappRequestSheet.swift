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
    /// The accounts the user picked for a ``DappApprovalRequest/chooseAccounts`` request.
    var onChooseAccounts: ([DappNamespace: Account]) -> Void = { _ in }

    @State private var editedFees: Fees?
    @State private var feeEstimationTask: Task<Void, Never>?
    /// Ethereum fees re-fetched with Estimate Fees, replacing the request's.
    @State private var reestimatedFees: Fees?

    var body: some View {
        Group {
            switch request {
            case .connect:
                connectSheet
            case let .chooseAccounts(_, selections):
                DappAccountChoiceView(
                    selections: selections,
                    site: site,
                    onChoose: onChooseAccounts,
                    onReject: { onResolve(.rejected, false) }
                )

            case let .signMessage(_, _, account, preview):
                messageSheet(account: account, preview: preview)
            case let .sendTransaction(_, _, account, preview):
                transactionSheet(account: account, preview: preview)
            }
        }
        .interactiveDismissDisabled(isProcessing)
    }
}

// MARK: - Subviews

private extension DappRequestSheet {
    @ViewBuilder
    var connectSheet: some View {
        if isIOS {
            Form {
                ParameterSection {
                    siteRow
                    FromRow(account: account, title: String(localized: .commonAccount))
                }

                Section {} footer: {
                    Text(.dappRequestConnectFooter)
                }
            }
            .phoneSheet(
                .commonConnectRequest,
                cancelTitle: .commonReject,
                cancelId: "dapp-reject-button",
                onCancel: { onResolve(.rejected, false) },
                confirmTitle: .commonApprove,
                confirmId: "dapp-approve-button",
                onConfirm: { onResolve(.approved, false) }
            )
        } else {
            macConnectSheet
        }
    }

    var macConnectSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(.commonConnectRequest)
                .style(.largeHeader)
                .accessibilityIdentifier("dapp-request-title")

            ParameterSection {
                siteRow
                FromRow(account: account, title: String(localized: .commonAccount))
            }

            Text(.dappRequestConnectFooter)
                .style(.small, foreground: .secondary)
                .padding(.top, 4)

            connectButtons
        }
        .padding(20)
#if os(macOS)
        .frame(width: 480)
#endif
    }

    var connectButtons: some View {
        HStack {
            Spacer()
            Button(.commonReject) {
                onResolve(.rejected, false)
            }
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("dapp-reject-button")

            Button(.commonApprove) {
                onResolve(.approved, false)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("dapp-approve-button")
        }
    }

    @ViewBuilder
    func messageSheet(account: Account, preview: DappMessagePreview) -> some View {
        let isTypedData = if case .ethereumTypedData = preview { true } else { false }

        let title = isTypedData
            ? String(localized: .dappRequestSignTypedData)
            : String(localized: .dappRequestSignMessage)

        signSheet(title: title) {
            switch preview {
            case let .aptosMessage(fullMessage):
                SignMessageParametersView(account: account, message: fullMessage, site: site)
            case let .cardanoCIP8(_, keyRole, payload):
                CardanoMessageParametersView(account: account, keyRole: keyRole, message: payload, site: site)
            case let .ethereumPersonal(message):
                SignMessageParametersView(account: account, message: message, site: site)
            case let .ethereumTypedData(summary):
                EthereumTypedDataParametersView(account: account, site: site, summary: summary)
            case let .solanaMessage(message):
                SignMessageParametersView(account: account, message: message, site: site)
            case let .suiPersonal(message):
                SignMessageParametersView(account: account, message: message, site: site)
            case let .tronMessage(message):
                SignMessageParametersView(account: account, message: message, site: site)
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
            confirmTitle: String(localized: .dappRequestConfirm),
            isConfirmEnabled: isConfirmEnabled,
            isProcessing: isProcessing,
            onEstimateFees: onEstimateFees,
            onCancel: { onResolve(.rejected, false) },
            onConfirm: { onResolve(approvedResult, true) },
            accessibilityIds: .init(
                cancel: "dapp-reject-button",
                confirm: "dapp-approve-button",
                title: "dapp-request-title"
            ),
            parameters: parameters,
            fees: fees
        )
    }

    @ViewBuilder
    func transactionSheet(account: Account, preview: DappTransactionPreview) -> some View {
        if case let .ethereum(call, _) = preview {
            signSheet(
                title: String(localized: .dappRequestSignTransaction),
                isConfirmEnabled: editedFees != nil,
                onEstimateFees: onEstimateEthereumFees
            ) {
                EthereumTransactionParametersView(account: account, call: call, site: site)
            } fees: {
                TransactionFeesView(
                    blockchain: account.blockchain,
                    estimatedFees: reestimatedFees ?? preview.fees,
                    // Not in Penpot: the user should know the site picked these values.
                    warning: call.hasDappFeeOverrides && reestimatedFees == nil
                        ? String(localized: .dappRequestDappFeeWarning)
                        : nil,
                    fees: $editedFees
                )
            }
        } else {
            signSheet(title: String(localized: .dappRequestSignTransaction)) {
                switch preview {
                case let .aptos(preview):
                    AptosTransactionParametersView(account: account, preview: preview, site: site)
                case let .cardano(preview):
                    CardanoTransactionParametersView(account: account, preview: preview, site: site)
                case .ethereum:
                    EmptyView()
                case let .solana(preview):
                    SolanaTransactionParametersView(account: account, preview: preview, site: site)
                case let .sui(preview):
                    SuiTransactionParametersView(account: account, preview: preview, site: site)
                case let .tron(preview):
                    TronTransactionParametersView(account: account, preview: preview, site: site)
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

    var siteRow: some View {
        ParameterRow(String(localized: .commonSite), value: site)
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
        // Never empty: the bridge only asks with at least one choice.
        case let .chooseAccounts(_, selections): selections[0].choices[0].account
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
        case let .chooseAccounts(origin, _): origin
        case let .signMessage(origin, _, _, _): origin
        case let .sendTransaction(origin, _, _, _): origin
        }
    }

    /// ``origin`` as the address bar shows it: `WKSecurityOrigin`'s port 0
    /// (the scheme's default) dropped, root path added.
    var site: String {
        guard var components = URLComponents(string: origin) else {
            return origin
        }

        if components.port == 0 {
            components.port = nil
        }

        components.path = "/"
        return components.string ?? origin
    }
}
