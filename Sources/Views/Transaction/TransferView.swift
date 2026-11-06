//
//  TransferView.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 22.02.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI
import WalletKit

// MARK: - TransferView

struct TransferView {
    private let account: Account
    private let initialBalance: Balance

    @State private var error: String?
    @State private var estimatedFees: Fees?
    @State private var feeEstimationTask: Task<Void, Never>?
    @State private var fees: Fees?
    @State private var isErrorAlertPresented = false
    @State private var parameters: TransferParameters?
    /// The send in flight, shown in the prompt popup; `nil` when idle.
    @State private var progress: TransactionProgress?
    @State private var token: Token

    @Environment(\.dismiss) private var dismiss

    init(balance: Balance) {
        account = balance.account
        initialBalance = balance
        _token = .init(initialValue: balance.token)
    }
}

// MARK: - View

extension TransferView: View {
    var body: some View {
        TransactionSheet(
            title: String(localized: .commonSend),
            confirmTitle: String(localized: .commonNext),
            isConfirmEnabled: isNextButtonEnabled,
            isEstimateFeesEnabled: parameters != nil,
            isProcessing: progress != nil,
            onEstimateFees: onEstimateFees,
            onCancel: onCancel,
            onConfirm: onNext,
            accessibilityIds: .init(confirm: "transfer-next-button", title: "transfer-sheet-title")
        ) {
            TransferParametersView(
                balance: initialBalance,
                nativeFeeReserve: nativeFeeReserve,
                parameters: $parameters,
                token: $token
            )
        } fees: {
            TransactionFeesView(
                blockchain: account.blockchain,
                estimatedFees: estimatedFees,
                isTronFeeLimitEnabled: !token.isNativeToken,
                fees: $fees
            )
        }
        .hardwareKeyPromptHost(progress: progress?.prompt)
        .alert(.transferTransactionFailed, isPresented: $isErrorAlertPresented) {
            Button(.commonOk) {
                isErrorAlertPresented = false
            }
        } message: {
            if let error {
                Text(error)
            } else {
                Text(.transferUnknownError)
            }
        }
        .onChange(of: parameters) { _, newValue in
            scheduleFeeEstimation(for: newValue)
        }
    }
}

// MARK: - Callbacks

private extension TransferView {
    func onCancel() {
        dismiss()
    }

    func onEstimateFees() {
        guard let parameters else {
            return
        }

        feeEstimationTask?.cancel()
        feeEstimationTask = Task {
            await estimateFees(for: parameters)
        }
    }

    func onNext() {
        guard let parameters, let fees else {
            return
        }

        Task { @MainActor in
            do {
                try await $progress.track {
                    try await sendTransaction(parameters: parameters, fees: fees)
                }

                dismiss()
            } catch {
                self.error = error.localizedDescription
                isErrorAlertPresented = true
            }
        }
    }
}

// MARK: - Logic

private extension TransferView {
    /// `true` once both transfer parameters and fees are set.
    var isNextButtonEnabled: Bool {
        parameters != nil && fees != nil
    }

    /// Native reserve required by the last fee estimate, if any. Passed to `TransferParametersView`.
    var nativeFeeReserve: BigUInt? {
        estimatedFees?.nativeFeeReserve.flatMap { BigUInt($0) }
    }

    /// Requests a fee estimate for `parameters` from the fee estimation service.
    func fetchFees(for parameters: TransferParameters) async throws -> Fees {
        let feeEstimationService = DI.injectOrFail(FeeEstimationService.self)
        return try await feeEstimationService.estimateFees(
            token: parameters.balance.token,
            decimalAmount: parameters.decimalAmount,
            cardanoRecipientLovelace: parameters.cardanoRecipientLovelace,
            recipient: parameters.recipient,
            account: account
        )
    }

    /// Fetches network fees for `parameters`, discarding the result if the
    /// parameters changed while the request was in flight.
    func estimateFees(for parameters: TransferParameters) async {
        do {
            let fees = try await fetchFees(for: parameters)

            guard self.parameters == parameters else {
                return
            }

            estimatedFees = fees
        } catch {
            printError(error)
            estimatedFees = nil
        }
    }

    /// Re-estimates fees for `parameters`, debounced to absorb rapid keystrokes
    /// before hitting the network. `nil` clears fees immediately, which is what
    /// keeps the Next button disabled while the form is invalid.
    func scheduleFeeEstimation(for parameters: TransferParameters?) {
        feeEstimationTask?.cancel()
        feeEstimationTask = nil
        estimatedFees = nil

        guard let parameters else {
            return
        }

        feeEstimationTask = Task {
            do {
                try await Task.sleep(for: .seconds(0.5))
            } catch {
                return  // cancelled during the delay
            }

            await estimateFees(for: parameters)
        }
    }

    func sendTransaction(parameters: TransferParameters, fees: Fees) async throws {
        let account = parameters.balance.account
        let databaseService = DI.injectOrFail(DatabaseService.self)

        let keyStore = try await databaseService.fetchKeyStore(id: account.keyStoreId)
        if let keyStore, keyStore.isHardware {
            progress = .signing
        }

        let transactionService = DI.injectOrFail(TransactionService.self)

        let txData = try await transactionService.makeTransaction(
            token: parameters.balance.token,
            decimalAmount: parameters.decimalAmount,
            cardanoRecipientLovelace: parameters.cardanoRecipientLovelace,
            recipient: parameters.recipient,
            account: account,
            fees: fees
        )

        let txSignature = try await transactionService.signTransaction(txData, account: account)

        progress = .sending
        let receipt = try await transactionService.sendTransaction(txData, txSignature, account: account)
        printDebug(receipt)
    }
}
