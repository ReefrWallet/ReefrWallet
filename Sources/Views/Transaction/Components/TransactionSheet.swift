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
    /// Replaces Cancel/Confirm with a progress indicator.
    var isProcessing = false
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
                        Button("Estimate Fees", action: onEstimateFees)
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

                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .disabled(isProcessing)
                        .accessibilityIdentifier(accessibilityIds.cancel)
                }

                ToolbarItem(placement: .confirmationAction) {
                    if isProcessing {
                        ProgressView()
                    } else {
                        Button(confirmTitle, action: onConfirm)
                            .disabled(!isConfirmEnabled)
                            .accessibilityIdentifier(accessibilityIds.confirm)
                    }
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
}

// MARK: - Subviews

#if os(macOS)
private extension TransactionSheet {
    var buttons: some View {
        HStack {
            if let onEstimateFees {
                Button("Estimate Fees", action: onEstimateFees)
                    .disabled(!isEstimateFeesEnabled)
            }

            Spacer()

            if isProcessing {
                ProgressView()
                    .controlSize(.small)

                Text("Signing...")
                    .style(.medium, foreground: .secondary)
            } else {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier(accessibilityIds.cancel)

                // Prominent, not `.defaultAction`: Return in a field must not send.
                Button(confirmTitle, action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .disabled(!isConfirmEnabled)
                    .accessibilityIdentifier(accessibilityIds.confirm)
            }
        }
    }

    var header: some View {
        Text(title)
            .style(.largeHeader)
            .accessibilityIdentifier(accessibilityIds.title)
    }
}
#endif
