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

    @State private var seedPhrase: String

    init(keyStore: KeyStore) {
        self.keyStore = keyStore

        if let entropy = keyStore.mnemonicEntropy,
           let mnemonic = try? Mnemonic.fromEntropy(entropy, wordlist: keyStore.mnemonicWordlist ?? .english) {
            _seedPhrase = State(initialValue: mnemonic.phrase)
        } else {
            _seedPhrase = State(initialValue: "")
        }
    }

    var body: some View {
        VStack(alignment: .leading) {
            Text("Recovery Phrase for \"\(keyStore.name)\"")
                .style(.medium, foreground: .primary)

            WordTokenizerView(phrase: $seedPhrase, columns: 4, readOnly: true)

            buttonsView
        }
        .padding()
    }
}

// MARK: - Subviews

private extension BackupKeyStoreView {
    var buttonsView: some View {
        HStack {
            Spacer()

            Button {
                dismiss()
            } label: {
                Text("Done")
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
    mnemonicEntropy: Mnemonic.generate(wordCount: .`24`).entropy,
    mnemonicWordlist: .english,
    transport: nil,
    vendor: nil
)

#Preview {
    BackupKeyStoreView(keyStore: previewKeyStore)
}

#endif
