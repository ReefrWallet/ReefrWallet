//
//  AddKeyStoreView.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 31.12.25.
//  Copyright © 2025 Reefr Wallet. All rights reserved.
//

import SwiftData
import SwiftUI
import WalletKit

// MARK: - AddKeyStoreView

struct AddKeyStoreView: View {
    enum FocusTarget: Hashable {
        case next
    }

    enum ViewState: Equatable {
        case chooseAction
        case newKey
        case newKeyType
        case restore
    }

    enum Options {
        static let connectTrezor = UUID()
        static let generateNewKey = UUID()
        static let restoreFromBackup = UUID()
    }

    @State private var error: Swift.Error?
    @State private var isAlertPresented = false
    @State private var isBackButtonDisabled = false
    @State private var generatedSlip39: Slip39GeneratedShare?
    @State private var isNextButtonDisabled = true
    @State private var newKeyType = RestoreBackupModel.BackupType.bip39
    @State private var newKeyWordCount = 12
    @State private var restore = RestoreBackupModel()
    @State private var seedPhrase = ""
    @State private var selectedOption: UUID?
    @State private var viewState: ViewState = .chooseAction

    @FocusState private var focus: FocusTarget?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.sidebarSelection) private var sidebarSelection: Binding<PersistentIdentifier?>

    private let databaseService = DI.injectOrFail(DatabaseService.self)
    private let keyStoreService = DI.injectOrFail(KeyStoreService.self)

    var body: some View {
        layout
        .interactiveDismissDisabled(restore.isRestoring)
        .onDisappear { restore.cancel() }
        .onChange(of: selectedOption) { _, newValue in
            switch newValue {
            case Options.connectTrezor:
                isNextButtonDisabled = false
            case Options.generateNewKey:
                isNextButtonDisabled = false
            case Options.restoreFromBackup:
                isNextButtonDisabled = false
            default:
                break
            }
        }
        .alert(.commonError, isPresented: $isAlertPresented) {
            Button(.commonOk) {
                isAlertPresented = false

                if case .alreadyExists = error as? ReefrError {
                    return
                }

                dismiss()
            }
        } message: {
            Text(verbatim: alertMessage(error))
        }
    }
}

// MARK: - Subviews

private extension AddKeyStoreView {
    @ViewBuilder
    var layout: some View {
        if isIOS {
            phoneLayout
        } else {
            VStack(alignment: .leading) {
                switch viewState {
                case .newKey:
                    generatedKeyView
                case .newKeyType:
                    newKeyTypeView
                case .chooseAction:
                    chooseKeyTypeView
                case .restore:
                    RestoreBackupView(model: restore)
                }

                buttonsView
            }
            .padding()
        }
    }

    /// iPhone: tappable option cards, then the phrase in an inset card.
    var phoneLayout: some View {
        Form {
            switch viewState {
            case .chooseAction:
                Section {
                    phoneOption(
                        Options.generateNewKey,
                        title: .addKeyStoreNewMnemonic,
                        detail: .addKeyStoreLocalKeyDescriptionPhone
                    )

                    phoneOption(
                        Options.restoreFromBackup,
                        title: .addKeyStoreRestoreFromBackup,
                        detail: .addKeyStoreRestoreDescriptionPhone
                    )
                }

            case .newKey:
                Section {
                    generatedKeyView
                }

            case .newKeyType:
                Section {
                    newKeyTypeView
                }

            case .restore:
                Section {
                    RestoreBackupView(model: restore)
                }

                if restore.step == .shares {
                    Section {
                        Button("Start Over") { restore.startOver() }
                    }
                }
            }
        }
        .phoneSheet(
            .sidebarAddKeyStore,
            cancelTitle: backButtonLabel,
            isCancelDisabled: isBackButtonDisabled || restore.isPersisting,
            onCancel: onBackButtonPressed,
            confirmTitle: nextButtonLabel,
            isConfirmEnabled: !isNextDisabled,
            onConfirm: onNextButtonPressed
        )
    }

    func phoneOption(_ option: UUID, title: LocalizedStringResource, detail: LocalizedStringResource) -> some View {
        Button {
            selectedOption = option
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .style(.large, foreground: .primary)

                    Text(detail)
                        .style(.caption, foreground: .secondary)
                        .multilineTextAlignment(.leading)
                }

                Spacer()

                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
                    .opacity(selectedOption == option ? 1 : 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    var buttonsView: some View {
        HStack {
            if viewState == .restore, restore.step == .shares {
                Button("Start Over") { restore.startOver() }
            }

            Spacer()

            Button {
                onBackButtonPressed()
            } label: {
                Text(backButtonLabel)
            }
            .focusable(viewState == .chooseAction)
            .focusEffectDisabled()
            .disabled(isBackButtonDisabled || restore.isPersisting)

            Button {
                onNextButtonPressed()
            } label: {
                Text(nextButtonLabel)
            }
            .focused($focus, equals: .next)
            .keyboardShortcut(.defaultAction)
            .disabled(isNextDisabled)
        }
    }

    var chooseKeyTypeView: some View {
        VStack {
            Picker("", selection: $selectedOption) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(.addKeyStoreNewHardwareKey)
                        .style(.medium, foreground: .primary)
                    Text(.addKeyStoreHardwareKeyDescription)
                        .style(.small, foreground: .secondary)
                }
                .tag(Options.connectTrezor)

                VStack(alignment: .leading, spacing: 4) {
                    Text(.addKeyStoreNewMnemonic)
                        .style(.medium, foreground: .primary)
                    Text(.addKeyStoreLocalKeyDescription)
                        .style(.small, foreground: .secondary)
                }
                .tag(Options.generateNewKey)

                VStack(alignment: .leading, spacing: 4) {
                    Text(.addKeyStoreRestoreFromBackup)
                        .style(.medium, foreground: .primary)
                    Text(.addKeyStoreRestoreDescription)
                        .style(.small, foreground: .secondary)
                }
                .tag(Options.restoreFromBackup)
            }
            #if os(macOS)
            .pickerStyle(.radioGroup)
            #endif
        }
    }

    @ViewBuilder
    var newKeyTypeView: some View {
        if isIOS {
            // Separate Form rows, so each control takes its own taps.
            BackupTypeControls(type: $newKeyType, wordCount: $newKeyWordCount)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                BackupTypeControls(type: $newKeyType, wordCount: $newKeyWordCount)
            }
        }
    }

    @ViewBuilder
    var generatedKeyView: some View {
        VStack(alignment: .leading, spacing: 8) {
            ReadOnlyPhraseView(phrase: seedPhrase, wordlist: generatedSlip39 == nil ? .bip39(.english) : .slip39)

            if generatedSlip39 != nil {
                Text(
                    "Write down these words and keep them safe. "
                        + "Reefr doesn't keep the share and can't show it again."
                )
                .style(.small, foreground: .secondary)
            }
        }
        .onChange(of: seedPhrase, initial: true) { _, newValue in
            validateSeedPhrase(newValue)
        }
    }
}

// MARK: - Logic

extension AddKeyStoreView {
    var backButtonLabel: LocalizedStringResource {
        switch viewState {
        case .chooseAction:
            .commonCancel
        case .newKey, .newKeyType, .restore:
            .commonBack
        }
    }

    var nextButtonLabel: LocalizedStringResource {
        switch viewState {
        case .newKey:
            .commonDone
        case .chooseAction, .newKeyType:
            .commonNext
        case .restore:
            restore.step == .shares && !restore.sharesCombine ? LocalizedStringResource("Add Share")
                : restore.nextRestores ? LocalizedStringResource("Restore") : .commonNext
        }
    }

    var isNextDisabled: Bool {
        switch viewState {
        case .newKeyType: false
        case .restore: !restore.isNextEnabled
        case .chooseAction, .newKey: isNextButtonDisabled
        }
    }

    func alertMessage(_ error: Swift.Error?) -> String {
        guard let error else {
            return String(localized: .commonUnknownError)
        }

        switch error {
        case ReefrError.alreadyExists:
            return String(localized: .addKeyStoreKeyStoreExists)
        default:
            return error.localizedDescription
        }
    }

    /// A fresh restore flow that saves the key store and closes the sheet.
    func makeRestoreModel() -> RestoreBackupModel {
        let model = RestoreBackupModel()
        model.save = { secret in
            switch secret {
            case let .bip39(mnemonic): try await keyStoreService.addLocalKey(mnemonic)
            case let .slip39(masterSecret): try await keyStoreService.addLocalKey(slip39MasterSecret: masterSecret)
            }
        }

        model.didSave = { dismiss() }
        return model
    }

    func onBackButtonPressed() {
        switch viewState {
        case .chooseAction:
            dismiss()
        case .newKey:
            generatedSlip39 = nil
            viewState = .newKeyType
        case .newKeyType:
            viewState = .chooseAction
        case .restore:
            if !restore.back() {
                viewState = .chooseAction
            }
        }
    }

    @MainActor
    func choose(_ option: UUID) async {
        switch option {
        case Options.connectTrezor:
            do {
                try await keyStoreService.connectTrezor()
                dismiss()
            } catch {
                self.error = error
                isAlertPresented = true
            }

        case Options.generateNewKey:
            viewState = .newKeyType
        case Options.restoreFromBackup:
            restore = makeRestoreModel()
            viewState = .restore
        default:
            preconditionFailure("Unknown option selected: \(option)")
        }
    }

    /// Generates the phrase picked on the type step and shows it.
    @MainActor
    func generateMnemonic() {
        switch newKeyType {
        case .bip39:
            generatedSlip39 = nil
            let wordCount = MnemonicWordCount(rawValue: UInt32(newKeyWordCount)) ?? .`12`
            seedPhrase = keyStoreService.generateSeedPhrase(wordCount: wordCount)
            viewState = .newKey
        case .slip39:
            do {
                let generated = try Slip39.generateSingleShare(strength: newKeyWordCount == 33 ? .bits256 : .bits128)
                generatedSlip39 = generated
                seedPhrase = generated.mnemonic
                viewState = .newKey
            } catch {
                self.error = error
                isAlertPresented = true
            }
        }
    }

    func onNextButtonPressed() {
        switch viewState {
        case .chooseAction:
            guard let selectedOption else {
                preconditionFailure("No option selected")
            }

            Task { await choose(selectedOption) }

        case .newKeyType:
            generateMnemonic()

        case .newKey:
            Task {
                do {
                    if let generatedSlip39 {
                        try await keyStoreService.addLocalKey(slip39MasterSecret: generatedSlip39.masterSecret)
                    } else {
                        try await keyStoreService.addLocalKey(Mnemonic.fromPhrase(seedPhrase))
                    }

                    dismiss()
                } catch {
                    self.error = error
                    isAlertPresented = true
                }
            }

        case .restore:
            Task { await restore.next() }
        }
    }

    @MainActor
    func validateSeedPhrase(_ seedPhrase: String) {
        guard generatedSlip39 == nil else {
            isNextButtonDisabled = false
            return
        }

        do {
            _ = try Mnemonic.fromPhrase(seedPhrase)
            isNextButtonDisabled = false
        } catch {
            isNextButtonDisabled = true
        }
    }
}

// MARK: - Preview

#Preview {
    AddKeyStoreView()
}
