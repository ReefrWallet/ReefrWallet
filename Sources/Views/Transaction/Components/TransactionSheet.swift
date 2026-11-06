//
//  TransactionSheet.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 21.10.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI

/// The shared send/sign sheet (ADR-042): a parameters section, an optional
/// fees section, then Estimate Fees, Cancel and Next/Confirm.
struct TransactionSheet<Parameters: View, Fees: View>: View {
    let title: String
    let confirmTitle: String
    let isConfirmEnabled: Bool
    var isEstimateFeesEnabled = true
    /// Disables Cancel/Confirm while the confirmed operation runs.
    var isProcessing = false
    /// Replaces "Cancel", as an outcome's Close does; `isCancelHidden` removes the button.
    var cancelTitle: String?
    var isCancelHidden = false
    /// Replaces "Estimate Fees", as an outcome's explorer link does.
    var estimateTitle: String?
    /// `nil` hides the Estimate Fees button.
    var onEstimateFees: (() -> Void)?
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var accessibilityIds = AccessibilityIds()

    @ViewBuilder let parameters: Parameters
    @ViewBuilder let fees: Fees

    var body: some View {
#if os(macOS)
        VStack(alignment: .leading, spacing: 16) {
            header
            parameters
            fees
            buttons
        }
        .textFieldStyle(.roundedBorder)
        .padding(20)
        .frame(width: 480)
#else
        NavigationStack {
            Form {
                parameters
                fees

                if let onEstimateFees {
                    Section {
                        Button(estimateText, action: onEstimateFees)
                            .frame(maxWidth: .infinity)
                            .disabled(!isEstimateFeesEnabled)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(title)
                        .style(.headline)
                        .accessibilityIdentifier(accessibilityIds.title)
                }

                if !isCancelHidden {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(cancelText, action: onCancel)
                            .disabled(isProcessing)
                            .accessibilityIdentifier(accessibilityIds.cancel)
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmTitle, action: onConfirm)
                        .disabled(!isConfirmEnabled || isProcessing)
                        .accessibilityIdentifier(accessibilityIds.confirm)
                }
            }
        }
#endif
    }
}

extension TransactionSheet {
    struct AccessibilityIds {
        var cancel = "transaction-cancel-button"
        var confirm = "transaction-confirm-button"
        var title = "transaction-sheet-title"
    }

    private var cancelText: String {
        cancelTitle ?? String(localized: .commonCancel)
    }

    private var estimateText: String {
        estimateTitle ?? String(localized: .transactionEstimateFees)
    }
}

// MARK: - Subviews

#if os(macOS)
private extension TransactionSheet {
    var buttons: some View {
        HStack {
            if let onEstimateFees {
                Button(estimateText, action: onEstimateFees)
                    .disabled(!isEstimateFeesEnabled)
            }

            Spacer()

            if !isCancelHidden {
                Button(cancelText, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isProcessing)
                    .accessibilityIdentifier(accessibilityIds.cancel)
            }

            // Prominent, not `.defaultAction`: Return in a field must not send.
            Button(confirmTitle, action: onConfirm)
                .buttonStyle(.borderedProminent)
                .disabled(!isConfirmEnabled || isProcessing)
                .accessibilityIdentifier(accessibilityIds.confirm)
        }
    }

    var header: some View {
        Text(title)
            .style(.largeHeader)
            .accessibilityIdentifier(accessibilityIds.title)
    }
}
#endif
