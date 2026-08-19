//
//  AddAccountView.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 31.12.25.
//  Copyright © 2025 Reefr Wallet. All rights reserved.
//

import SwiftData
import SwiftUI
import WalletKit

// MARK: - AddAccountView

struct AddAccountView: View {
    let keyStore: KeyStore

    @State private var address = ""
    @State private var blockchains: [BlockchainConfig]
    @State private var error: Swift.Error?
    @State private var isAlertPresented = false
    @State private var networks: [BlockchainConfig]

    @State private var selectedBlockchain: BlockchainConfig?
    @State private var selectedKeyScheme: Curve?
    @State private var selectedNetwork: BlockchainConfig?

    @Query private var savedBlockchains: [BlockchainConfig]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.sidebarSelection) private var sidebarSelection: Binding<PersistentIdentifier?>

    private let blockchainConfigService: BlockchainConfigService
    private let databaseService: DatabaseService

    init(keyStore: KeyStore) {
        self.keyStore = keyStore

        self.blockchainConfigService = DI.injectOrFail(BlockchainConfigService.self)
        self.databaseService = DI.injectOrFail(DatabaseService.self)

        let blockchains = blockchainConfigService.configuredBlockchains
            .filter { !$0.isTestnet && $0.presetId != nil }

        self.blockchains = blockchains
        self.selectedBlockchain = blockchains.first

        if let selectedBlockchain = blockchains.first {
            let networks = blockchainConfigService.configuredBlockchains
                .filter { $0.blockchain == selectedBlockchain.blockchain }
            self.networks = networks
            self.selectedNetwork = networks.first
        } else {
            self.networks = []
        }
    }
}

// MARK: - View

extension AddAccountView {
    var body: some View {
        VStack {
            Text("Add Blockchain Account")
                .style(.largeHeader, foreground: .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom)

            Form {
                Section {
                    Picker("Blockchain", selection: $selectedBlockchain) {
                        ForEach(blockchains, id: \.self) { blockchain in
                            Text(blockchain.displayName)
                                .tag(blockchain)
                        }
                    }

                    Picker("Network", selection: $selectedNetwork) {
                        ForEach(networks, id: \.self) { blockchain in
                            Text(blockchain.networkName)
                                .tag(blockchain)
                        }
                    }

                    if case .sui = selectedBlockchain?.blockchain {
                        Picker("Key Scheme", selection: $selectedKeyScheme) {
                            ForEach(Curve.allCases, id: \.self) { scheme in
                                Text(scheme.description)
                                    .tag(scheme)
                            }
                        }
                    }
                }

                if keyStore.isWatchOnly {
                    Section {
                        TextField("Watch Address", text: $address)
                            .disabled(selectedNetwork == nil)
                            .padding()
                    }
                }
            }
            .padding(.bottom)

            buttonsView
        }
        .padding()
        .alert("Error", isPresented: $isAlertPresented) {
            Button("OK") {
                isAlertPresented = false
                dismiss()
            }
        } message: {
            Text(alertMessage(error))
        }
        .onChange(of: selectedBlockchain, initial: true) { _, newValue in
            didSelectBlockchain(newValue)
        }
    }
}

// MARK: - Subviews

private extension AddAccountView {
    var buttonsView: some View {
        HStack {
            Spacer()

            Button {
                dismiss()
            } label: {
                Text("Cancel")
            }

            Button {
                Task {
                    do {
                        try await addAccount(selectedNetwork!, signatureScheme: selectedKeyScheme)
                    } catch {
                        self.error = error
                        isAlertPresented = true
                    }
                }
            } label: {
                Text("Add Account")
            }
            .disabled(selectedNetwork == nil)
        }
    }
}

// MARK: - Logic

extension AddAccountView {
    @MainActor
    func addAccount(_ blockchain: BlockchainConfig, signatureScheme: Curve?) async throws {
        let blockchain = savedBlockchains
            .first { $0.presetId == blockchain.presetId }
            ?? blockchain

        let accountService = DI.injectOrFail(AccountService.self)

        let account = try await accountService.makeAccount(
            blockchain,
            keyStore: keyStore
        )

        if keyStore.isWatchOnly {
            func setWatchOnlyAddress(_ account: Account) throws {
                switch account.blockchainConfig.blockchain {
                case .ethereum:
                    _ = try EthereumAddress(string: address)
                    account.address = address
                case .sui:
                    _ = try SuiAddress(string: address)
                    account.address = address
                default:
                    throw Error.notImplemented
                }
            }
        }

        sidebarSelection.wrappedValue = account.id
        dismiss()
    }

    func alertMessage(_ error: Swift.Error?) -> String {
        guard let error else {
            return "Unknown Error."
        }

        switch error {
        case Error.alreadyExists:
            return "Account already exists."
        default:
            return error.localizedDescription
        }
    }

    func didSelectBlockchain(_ blockchain: BlockchainConfig?) {
        if let blockchain {
            networks = blockchainConfigService.configuredBlockchains.filter {
                $0.blockchain == blockchain.blockchain
            }

            selectedNetwork = networks.first

            if case .sui = blockchain.blockchain {
                selectedKeyScheme = .ed25519
            } else {
                selectedKeyScheme = nil
            }
        }
    }
}

// MARK: - Preview

#Preview {
    AddAccountView(keyStore: .mockWatchOnly())
        .frame(width: 400)
}
