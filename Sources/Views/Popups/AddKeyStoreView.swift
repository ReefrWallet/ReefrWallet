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
        case newKey
        case chooseAction
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
    @State private var isNextButtonDisabled = true
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
            Text(alertMessage(error))
        }
    }
}

// MARK: - Subviews

private extension AddKeyStoreView {
    @ViewBuilder
    var layout: some View {
        if isPhone {
            phoneLayout
        } else {
            VStack(alignment: .leading) {
                switch viewState {
                case .newKey:
                    generatedKeyView
                case .chooseAction:
                    chooseKeyTypeView
                case .restore:
                    editableKeyView
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
                        title: .addKeyStoreNewBip39Mnemonic,
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

            case .restore:
                Section {
                    editableKeyView
                }
            }
        }
        .phoneSheet(
            .sidebarAddKeyStore,
            cancelTitle: backButtonLabel,
            isCancelDisabled: isBackButtonDisabled,
            onCancel: onBackButtonPressed,
            confirmTitle: nextButtonLabel,
            isConfirmEnabled: !isNextButtonDisabled,
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
            Spacer()

            Button {
                onBackButtonPressed()
            } label: {
                Text(backButtonLabel)
            }
            .focusable(viewState == .chooseAction)
            .focusEffectDisabled()
            .disabled(isBackButtonDisabled)

            Button {
                onNextButtonPressed()
            } label: {
                Text(nextButtonLabel)
            }
            .focused($focus, equals: .next)
            .keyboardShortcut(.defaultAction)
            .disabled(isNextButtonDisabled)
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
                    Text(.addKeyStoreNewBip39Mnemonic)
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

    var editableKeyView: some View {
        WordTokenizerView(
            phrase: $seedPhrase,
            columns: isPhone ? 3 : 4
        )
            .onChange(of: seedPhrase, initial: true) { _, newValue in
                validateSeedPhrase(newValue)
            }
    }

    var generatedKeyView: some View {
        WordTokenizerView(phrase: $seedPhrase, columns: isPhone ? 3 : 4, readOnly: true)
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
        case .newKey, .restore:
            .commonBack
        }
    }

    var nextButtonLabel: LocalizedStringResource {
        switch viewState {
        case .newKey:
            .commonDone
        case .chooseAction, .restore:
            .commonNext
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

    func onBackButtonPressed() {
        switch viewState {
        case .chooseAction:
            dismiss()
        case .newKey, .restore:
            viewState = .chooseAction
        }
    }

    func onNextButtonPressed() {
        switch viewState {
        case .chooseAction:
            guard let selectedOption else {
                preconditionFailure("No option selected")
            }

            Task {
                switch selectedOption {
                case Options.connectTrezor:
                    do {
                        try await keyStoreService.connectTrezor()
                        dismiss()
                    } catch {
                        self.error = error
                        isAlertPresented = true
                    }

                case Options.generateNewKey:
                    seedPhrase = keyStoreService.generateSeedPhrase()
                    viewState = .newKey
                case Options.restoreFromBackup:
                    seedPhrase = ""
                    viewState = .restore
                default:
                    preconditionFailure("Unknown option selected: \(selectedOption)")
                }
            }

        case .newKey, .restore:
            Task {
                do {
                    let mnemonic = try Mnemonic.fromPhrase(seedPhrase)
                    try await keyStoreService.addLocalKey(mnemonic)
                    dismiss()
                } catch {
                    self.error = error
                    isAlertPresented = true
                }
            }
        }
    }

    @MainActor
    func validateSeedPhrase(_ seedPhrase: String) {
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
