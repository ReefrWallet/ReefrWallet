//
//  NFTTransferView.swift
//  Reefr Wallet
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import SwiftUI
import WalletKit

// MARK: - NFTTransferParameters

struct NFTTransferParameters: Equatable {
    let cardanoRecipientLovelace: String?
    let quantity: BigUInt
    let recipient: String
}

// MARK: - NFTTransferView

/// Sends an NFT through the shared Transaction Sheet (ADR-042), waiting for
/// on-chain confirmation before the holding changes (ADR-072).
struct NFTTransferView {
    let account: Account
    let nft: NFT

    @State private var error: String?
    @State private var estimatedFees: Fees?
    @State private var feeEstimationTask: Task<Void, Never>?
    @State private var fees: Fees?
    @State private var isErrorAlertPresented = false
    @State private var parameters: NFTTransferParameters?
    @State private var progress: TransactionProgress?

    @Environment(\.dismiss) private var dismiss
}

extension NFTTransferView: View {
    var body: some View {
        TransactionSheet(
            title: String(localized: .nftTransferTitle),
            confirmTitle: String(localized: .commonNext),
            isConfirmEnabled: parameters != nil && fees != nil,
            isEstimateFeesEnabled: parameters != nil,
            isProcessing: progress != nil,
            onEstimateFees: onEstimateFees,
            onCancel: onCancel,
            onConfirm: onNext,
            accessibilityIds: .init(confirm: "nft-transfer-next-button", title: "nft-transfer-sheet-title")
        ) {
            NFTTransferParametersView(account: account, nft: nft, parameters: $parameters)
        } fees: {
            TransactionFeesView(
                blockchain: account.blockchain,
                estimatedFees: estimatedFees,
                isTronFeeLimitEnabled: false,
                fees: $fees
            )
        }
        .hardwareKeyPromptHost(progress: progress?.prompt)
        .alert(.transferTransactionFailed, isPresented: $isErrorAlertPresented) {
            Button(.commonOk) {
                isErrorAlertPresented = false
                dismissIfBroadcast()
            }
        } message: {
            Text(verbatim: error ?? String(localized: .transferUnknownError))
        }
        .onChange(of: parameters) { _, newValue in
            scheduleFeeEstimation(for: newValue)
        }
    }
}

// MARK: - Callbacks

private extension NFTTransferView {
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
                    try await send(parameters: parameters, fees: fees)
                }

                dismiss()
            } catch {
                self.error = error.localizedDescription
                isErrorAlertPresented = true
            }
        }
    }

    /// After an unconfirmed broadcast the NFT is locked; there's nothing left to edit.
    func dismissIfBroadcast() {
        if error == String(localized: .nftTransferUnconfirmed) || error == String(localized: .nftTransferFailed) {
            dismiss()
        }
    }
}

// MARK: - Logic

private extension NFTTransferView {
    func estimateFees(for parameters: NFTTransferParameters) async {
        do {
            let fees = try await DI.injectOrFail(FeeEstimationService.self).estimateNFTFees(
                nft: nft.reference,
                quantity: parameters.quantity,
                cardanoRecipientLovelace: parameters.cardanoRecipientLovelace,
                recipient: parameters.recipient,
                account: account
            )

            guard self.parameters == parameters else {
                return
            }

            estimatedFees = fees
        } catch {
            printError(error)
            estimatedFees = nil
        }
    }

    func scheduleFeeEstimation(for parameters: NFTTransferParameters?) {
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
                return
            }

            await estimateFees(for: parameters)
        }
    }

    func send(parameters: NFTTransferParameters, fees: Fees) async throws {
        let databaseService = DI.injectOrFail(DatabaseService.self)
        let nftService = DI.injectOrFail(NFTService.self)
        let transactionService = DI.injectOrFail(TransactionService.self)

        if try await databaseService.fetchKeyStore(id: account.keyStoreId)?.isHardware == true {
            progress = .signing
        }

        let objectReference = try await NFTSendRecord.suiObjectReference(nft: nft.reference, account: account)
        let transaction = try await transactionService.makeNFTTransaction(
            nft: nft.reference,
            quantity: parameters.quantity,
            cardanoRecipientLovelace: parameters.cardanoRecipientLovelace,
            recipient: parameters.recipient,
            account: account,
            fees: fees
        )

        let signature = try await transactionService.signTransaction(transaction, account: account)
        let record = try await NFTSendRecord.make(
            nft: nft,
            quantity: parameters.quantity,
            transaction: transaction,
            suiObjectReference: objectReference,
            account: account
        )

        progress = .sending
        let hash = try await transactionService.sendTransaction(transaction, signature, account: account)
        try await nftService.recordBroadcast(record.withHash(hash), account: account)

        progress = .confirming
        let isSelfSend = try await NFTSendRecord.isOwnAddress(parameters.recipient, account: account)
        try await nftService.confirm(txHash: hash, isSelfSend: isSelfSend, account: account)
    }
}

// MARK: - NFTTransferParametersView

struct NFTTransferParametersView: View {
    let account: Account
    let nft: NFT

    @Binding var parameters: NFTTransferParameters?

    @State private var cardanoRecipientLovelaceText = ""
    @State private var quantityText = "1"
    @State private var receiverText = ""

    var body: some View {
        ParameterSection(String(localized: .transferParametersTransfer)) {
            FromRow(account: account)

            ParameterRow(String(localized: .nftTransferNft)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: nft.displayName)
                        .style(.medium, foreground: .primary)

                    Text(verbatim: nft.collectionName ?? nft.reference.collection)
                        .style(.small, foreground: .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if nft.hasQuantity {
                ParameterRow(String(localized: .nftTransferQuantity)) {
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("", text: $quantityText)
                            .accessibilityIdentifier("nft-transfer-quantity-field")

                        Text(.nftTransferOwned(nft.quantity.description))
                            .style(.small, foreground: .secondary)
                    }
                }
            }

            if isCardano {
                ParameterRow(String(localized: .transferParametersRecipientLovelace)) {
                    TextField("", text: $cardanoRecipientLovelaceText)
                }
            }

            ParameterRow(String(localized: .transferParametersReceiver)) {
                TextField("", text: $receiverText, prompt: Text(verbatim: account.blockchain.recipientPrompt))
                    .accessibilityIdentifier("nft-transfer-receiver-field")
            }
        }
        .onChange(of: validated, initial: true) { _, newValue in
            parameters = newValue
        }
    }

    private var isCardano: Bool {
        if case .cardano = account.blockchain {
            return true
        }

        return false
    }

    private var validated: NFTTransferParameters? {
        let receiver = receiverText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard account.blockchain.isValidRecipient(receiver),
              let quantity = BigUInt(quantityText.trimmingCharacters(in: .whitespaces)),
              quantity > 0, quantity <= nft.quantity
        else {
            return nil
        }

        if isCardano, UInt64(cardanoRecipientLovelaceText) == nil {
            return nil
        }

        return NFTTransferParameters(
            cardanoRecipientLovelace: isCardano ? cardanoRecipientLovelaceText : nil,
            quantity: quantity,
            recipient: receiver
        )
    }
}
