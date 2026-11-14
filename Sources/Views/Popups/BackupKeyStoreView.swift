//
//  BackupKeyStoreView.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 08.10.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI
import WalletKit

// MARK: - BackupKeyStoreView

/// Shows an existing local key store's recovery phrase, read-only, for
/// backup purposes. The caller authenticates and passes the phrase in.
struct BackupKeyStoreView: View {
    let keyStore: KeyStore
    let phrase: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        content
    }
}

// MARK: - Subviews

private extension BackupKeyStoreView {
    @ViewBuilder
    var content: some View {
        if isIOS {
            Form {
                Section {
                    recoveryPhrase
                } header: {
                    Text(.backupKeyStoreRecoveryPhraseTitle(keyStore.name))
                        .textCase(nil)
                }
            }
            .phoneSheet(
                .backupKeyStoreRecoveryPhrase,
                cancelTitle: .commonDone,
                onCancel: { dismiss() }
            )
        } else {
            VStack(alignment: .leading) {
                Text(.backupKeyStoreRecoveryPhraseTitle(keyStore.name))
                    .style(.medium, foreground: .primary)

                recoveryPhrase

                buttonsView
            }
            .padding()
        }
    }

    @ViewBuilder
    var recoveryPhrase: some View {
        if keyStore.secretKind == .slip39 {
            Text(.backupKeyStoreSlip39Message)
                .style(.medium, foreground: .secondary)
        } else {
            ReadOnlyPhraseView(phrase: phrase, wordlist: .bip39(keyStore.mnemonicWordlist ?? .english))
        }
    }

    var buttonsView: some View {
        HStack {
            Spacer()

            Button {
                dismiss()
            } label: {
                Text(.commonDone)
            }
        }
    }
}

// MARK: - Preview

#if DEBUG

private let previewKeyStore = KeyStore(
    deviceId: nil,
    kind: .local,
    name: "Local Key",
    mnemonicWordlist: .english,
    sealedEntropy: Mnemonic.generate(wordCount: .`24`).entropy,
    transport: nil,
    vendor: nil
)

#Preview {
    BackupKeyStoreView(keyStore: previewKeyStore, phrase: Mnemonic.generate(wordCount: .`24`).phrase)
}

#endif
