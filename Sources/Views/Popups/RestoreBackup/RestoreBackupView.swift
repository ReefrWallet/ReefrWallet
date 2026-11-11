//
//  RestoreBackupView.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 11.11.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI
import WalletKit

/// The content of each restore step; the owner supplies Back/Next.
struct RestoreBackupView: View {
    @Bindable var model: RestoreBackupModel

    var body: some View {
        switch model.step {
        case .type: typeStep
        case .words: wordsStep
        case .shares: sharesStep
        case .passphrase: passphraseStep
        }
    }
}

// MARK: - Steps

private extension RestoreBackupView {
    @ViewBuilder
    var typeStep: some View {
        if isIOS {
            // Separate Form rows, so each control takes its own taps.
            typeControls
        } else {
            VStack(alignment: .leading, spacing: 12) {
                typeControls
            }
        }
    }

    var typeControls: some View {
        BackupTypeControls(type: $model.type, wordCount: $model.wordCount, isLocked: model.isTypeLocked)
    }

    var wordsStep: some View {
        VStack(alignment: .leading, spacing: 6) {
            SeedPhraseField(model: model.field)

            if let message = wordsMessage {
                Text(verbatim: message)
                    .style(.small, foreground: .negative)
                    .accessibilityIdentifier("seed-phrase-message")
            }

            if let failure = model.failure {
                Text(verbatim: failure.localizedDescription)
                    .style(.small, foreground: .negative)
                    .accessibilityIdentifier("restore-failure")
            }
        }
    }

    var sharesStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: sharesHeading)
                .style(.smallHeader, foreground: .secondary)

            ForEach(Array(model.shares.shares.enumerated()), id: \.element) { offset, share in
                HStack {
                    Text(verbatim: "Share \(offset + 1) · member \(share.memberIndex + 1)")
                        .style(.medium, foreground: .primary)

                    Spacer()

                    Button("Remove") { model.removeShare(share) }
                        .accessibilityIdentifier("restore-remove-share-\(offset)")
                }
            }

            if let error = model.shareError {
                Text(verbatim: message(for: error))
                    .style(.small, foreground: .negative)
            }
        }
    }

    var passphraseStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Backup is protected by a passphrase", isOn: $model.usesPassphrase)
                .disabled(model.isRestoring)

            if model.usesPassphrase {
                SecureField("Passphrase", text: $model.passphrase)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .disabled(model.isRestoring)

                if !model.isPassphraseValid, !model.passphrase.isEmpty {
                    Text("Only printable ASCII characters (letters, digits, symbols, space) are supported.")
                        .style(.small, foreground: .negative)
                }
            }

            Text(model.isRestoring
                 ? "Restoring… this can take a while."
                 : model.usesPassphrase
                 ? "Used exactly as typed: case and spaces matter. A wrong passphrase opens a different wallet."
                 : "Leave off if your backup has no passphrase. An empty passphrase is used.")
                .style(.small, foreground: .secondary)

            if let failure = model.failure {
                Text(verbatim: failure.localizedDescription)
                    .style(.small, foreground: .negative)
                    .accessibilityIdentifier("restore-failure")
            }
        }
    }
}

// MARK: - Messages

private extension RestoreBackupView {
    var sharesHeading: String {
        let set = model.shares

        if let threshold = set.groupThreshold, threshold > 1 {
            return "\(set.completeGroupCount) of \(threshold) required groups complete"
        }

        let group = set.groups.first
        return "\(group?.shares.count ?? 0) of \(group?.memberThreshold ?? 0) required shares entered"
    }

    var wordsMessage: String? {
        let words = model.wordCount

        switch model.field.inputError {
        case let .pasteRejected(count):
            return "You entered \(count) words, but this backup has \(words). "
                + "Nothing was added — change the word count to enter more."
        case let .tooManyWords(count):
            return "\(count) words entered for a \(words)-word backup. Remove \(count - words) words or change the word count."
        case let .unsupportedLength(count):
            return "\(count)-word shares aren't supported. Reefr supports 20- and 33-word shares."
        case nil:
            break
        }

        if model.hasChecksumError {
            return "All words are valid, but the phrase doesn't check out. Check the order and spelling."
        }

        return model.shareError.map(message(for:))
    }

    func message(for error: Slip39Error) -> String {
        switch error {
        case .duplicateShare: "This share is already entered."
        case .conflictingShare: "Another share with the same index is already entered."
        case .invalidDigest: "Shares don't combine. Remove a share or start over."
        case .invalidChecksum: "This share's checksum is wrong. Check the words."
        case let .invalidSet(reason): "\(reason) Remove it or start over."
        case let .unsupportedLength(count): "\(count)-word shares aren't supported. Reefr supports 20- and 33-word shares."
        case let .unknownWord(word): "\"\(word)\" isn't a SLIP-39 word."
        default: error.localizedDescription
        }
    }
}

// MARK: - BackupTypeControls

/// Backup type (BIP-39 or SLIP-39) and word count, as separate rows on iOS.
struct BackupTypeControls: View {
    @Binding var type: RestoreBackupModel.BackupType
    @Binding var wordCount: Int

    var isLocked = false

    var body: some View {
        Picker("", selection: $type) {
            option("BIP-39", detail: "12, 15, 18, 21 or 24 words").tag(RestoreBackupModel.BackupType.bip39)
            option("SLIP-39", detail: "20- or 33-word shares").tag(RestoreBackupModel.BackupType.slip39)
        }
        .pickerStyle(.inline)
        .labelsHidden()
        .disabled(isLocked)

        Picker(selection: $wordCount) {
            ForEach(type.wordCounts, id: \.self) { count in
                Text(verbatim: "\(count)").tag(count)
            }
        } label: {
            Text("Words")
        }
        .disabled(isLocked)
        .onChange(of: type) { _, newValue in
            if !newValue.wordCounts.contains(wordCount) {
                wordCount = newValue.wordCounts[0]
            }
        }
    }

    private func option(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: title).style(.medium, foreground: .primary)
            Text(verbatim: detail).style(.small, foreground: .secondary)
        }
    }
}
