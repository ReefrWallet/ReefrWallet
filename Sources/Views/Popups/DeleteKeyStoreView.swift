//
//  DeleteKeyStoreView.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 14.11.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI
import WalletKit

// MARK: - DeleteKeyStoreView

/// Confirms key store deletion. A local key store also requires acknowledging
/// that it was backed up and authenticating.
struct DeleteKeyStoreView: View {
    let keyStore: KeyStore
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var isAuthenticating = false
    @State private var isBackupConfirmed = false

    var body: some View {
        content
    }
}

// MARK: - Subviews

private extension DeleteKeyStoreView {
    @ViewBuilder
    var content: some View {
        if isIOS {
            Form {
                Section {
                    if keyStore.isLocal {
                        backupToggle
                    }
                } header: {
                    message
                        .textCase(nil)
                }
            }
            .phoneSheet(
                .sidebarDeleteKeyStoreTitle,
                onCancel: { dismiss() },
                confirmTitle: .sidebarDelete,
                confirmRole: .destructive,
                isConfirmEnabled: isDeleteEnabled,
                onConfirm: delete
            )
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text(.sidebarDeleteKeyStoreTitle)
                    .style(.headline, foreground: .primary)

                message

                if keyStore.isLocal {
                    backupToggle
                }

                buttonsView
            }
            .padding()
            .frame(width: 420)
        }
    }

    var backupToggle: some View {
        Toggle(.deleteKeyStoreBackupConfirmation, isOn: $isBackupConfirmed)
    }

    var buttonsView: some View {
        HStack {
            Spacer()

            Button(.commonCancel) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Button(.sidebarDelete, role: .destructive, action: delete)
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(!isDeleteEnabled)
        }
    }

    var message: some View {
        Text(
            keyStore.isLocal
                ? .deleteKeyStoreLocalMessage(keyStore.name)
                : .deleteKeyStoreHardwareMessage(keyStore.name)
        )
        .style(.medium, foreground: isIOS ? .secondary : .primary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Logic

private extension DeleteKeyStoreView {
    var isDeleteEnabled: Bool {
        !isAuthenticating && (!keyStore.isLocal || isBackupConfirmed)
    }

    func delete() {
        guard isDeleteEnabled else {
            return
        }

        guard keyStore.isLocal else {
            onDelete()
            dismiss()
            return
        }

        isAuthenticating = true

        Task {
            defer { isAuthenticating = false }

            do {
                let reason = String(localized: .deleteKeyStoreAuthenticationReason(keyStore.name))
                _ = try await keyStore.localEntropy(reason: reason)
                onDelete()
            } catch {
                printError(error)
            }

            dismiss()
        }
    }
}

// MARK: - Preview

#if DEBUG

#Preview {
    DeleteKeyStoreView(
        keyStore: KeyStore(
            deviceId: nil,
            kind: .local,
            name: "Local Key",
            mnemonicWordlist: .english,
            sealedEntropy: Mnemonic.generate(wordCount: .`24`).entropy,
            transport: nil,
            vendor: nil
        ),
        onDelete: {}
    )
}

#endif
