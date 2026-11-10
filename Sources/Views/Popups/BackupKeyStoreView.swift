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
/// backup purposes.
struct BackupKeyStoreView: View {
    let keyStore: KeyStore

    @Environment(\.dismiss) private var dismiss

    @State private var seedPhrase = ""

    init(keyStore: KeyStore) {
        self.keyStore = keyStore
    }

    var body: some View {
        content
            .task {
                do {
                    let mnemonic = try await keyStore.localMnemonic(reason: "Authenticate to show your recovery phrase")
                    seedPhrase = mnemonic.phrase
                } catch {
                    printError(error)
                    dismiss()
                }
            }
    }
}

// MARK: - Subviews

private extension BackupKeyStoreView {
    @ViewBuilder
    var content: some View {
        if isIOS {
            Form {
                Section {
                    WordTokenizerView(phrase: $seedPhrase, columns: 3, readOnly: true)
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

                WordTokenizerView(phrase: $seedPhrase, columns: 4, readOnly: true)

                buttonsView
            }
            .padding()
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
    BackupKeyStoreView(keyStore: previewKeyStore)
}

#endif
