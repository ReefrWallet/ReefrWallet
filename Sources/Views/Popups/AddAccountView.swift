// swiftlint:disable file_length
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

struct AddAccountView {
    let keyStore: KeyStore

    @State private var address = ""
    @State private var blockchains: [Blockchain]
    @State private var error: Swift.Error?
    @State private var isAlertPresented = false
    @State private var networks: [Blockchain]

    @State private var customChainId: String
    @State private var selectedBlockchain: Blockchain
    @State private var selectedKeyScheme: Curve?
    @State private var selectedNetwork: Blockchain?
    @State private var selectedBitcoinScriptType: BitcoinScriptType = .p2wpkh
    @State private var selectedBitcoinBackend: BitcoinBackendKind = .electrum

    @State private var customDerivationPath = ""
    @State private var nextDerivationPath: DerivationPath?
    @State private var useCustomDerivationPath = false

    @State private var customEndpointURL: String = ""
    @State private var useCustomEndpoint: Bool = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.sidebarSelection) private var sidebarSelection: Binding<PersistentIdentifier?>

    private let accountService = DI.injectOrFail(AccountService.self)

    init(keyStore: KeyStore) {
        self.keyStore = keyStore

        // "Other EVM" goes last, below a divider in the picker.
        let allMainnets = Blockchain.allMainnets
        let blockchains = allMainnets.filter { !$0.isCustomEVM } + allMainnets.filter(\.isCustomEVM)
        // Unsupported chains stay listed (disabled), so never preselect one.
        let selectedBlockchain = blockchains.first { $0.isSupported(by: keyStore) }!
        let networks = selectedBlockchain.allNetworks

        self.blockchains = blockchains
        self.networks = networks
        self.selectedNetwork = networks.first
        self.selectedBlockchain = selectedBlockchain

        if case let .evm(chain) = selectedBlockchain {
            customChainId = "\(chain.chainId)"
        } else {
            customChainId = ""
        }
    }
}

// MARK: - View

extension AddAccountView: View {
    var body: some View {
        VStack {
            Text("Add Blockchain Account")
                .style(.largeHeader, foreground: .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom)

            Form {
                Section {
                    blockchainPicker

                    if !selectedBlockchain.isCustomEVM {
                        Picker("Network", selection: $selectedNetwork) {
                            ForEach(networks, id: \.self) { blockchain in
                                Text("\(blockchain.networkName)").tag(blockchain)
                            }
                        }
                        .accessibilityIdentifier("add-account-network-picker")
                    }

                    if selectedBlockchain.isCustomEVM {
                        TextField("ChainId", text: $customChainId)
                            .disabled(!selectedBlockchain.isCustomEVM)
                    } else if selectedBlockchain.hasKeySchemeChoice, !keyStore.isWatchOnly {
                        Picker("Key Scheme", selection: $selectedKeyScheme) {
                            ForEach(Curve.allCases, id: \.self) { scheme in
                                Text(scheme.description).tag(scheme)
                            }
                        }
                    } else if case .bitcoin = selectedBlockchain, !keyStore.isWatchOnly {
                        Picker("Script Type", selection: $selectedBitcoinScriptType) {
                            Text("Native SegWit (BIP-84)").tag(BitcoinScriptType.p2wpkh)
                            Text("Taproot (BIP-86)").tag(BitcoinScriptType.p2tr)
                        }
                    }

                    if case .bitcoin = selectedBlockchain {
                        // Set only here, at account creation — like the RPC
                        // endpoint override below, there is no later
                        // edit-account flow for this yet.
                        Picker("Backend", selection: $selectedBitcoinBackend) {
                            ForEach(BitcoinBackendKind.allCases, id: \.self) { backend in
                                Text(backend.displayName).tag(backend)
                            }
                        }
                        .accessibilityIdentifier("add-account-bitcoin-backend-picker")
                    }
                }

                if supportsCustomDerivationPath {
                    Section {
                        let displayedDerivationPath: Binding<String> = .init(get: {
                            useCustomDerivationPath && !customDerivationPath.isEmpty
                                ? customDerivationPath
                                : nextDerivationPath?.string ?? ""
                        }, set: { newValue in
                            if useCustomDerivationPath {
                                customDerivationPath = newValue
                            }
                        })

                        TextField("Derivation Path", text: displayedDerivationPath)
                            .disabled(!useCustomDerivationPath)
                            .padding(.top)
                            .accessibilityIdentifier("add-account-derivation-path-field")

                        Toggle("Custom Derivation Path", isOn: $useCustomDerivationPath)
                            .accessibilityIdentifier("add-account-derivation-path-toggle")
                    }
                }

                Section {
                    let displayedRpcUrl: Binding<String> = .init(get: {
                        if useCustomEndpoint, !customEndpointURL.isEmpty {
                            customEndpointURL
                        } else if case let .bitcoin(network) = selectedNetwork {
                            network.defaultEndpoint(for: selectedBitcoinBackend).absoluteString
                        } else {
                            selectedNetwork?.rpcURL.absoluteString ?? ""
                        }
                    }, set: { newValue in
                        if useCustomEndpoint {
                            customEndpointURL = newValue
                        }
                    })

                    let customRPCEnabled: Binding<Bool> = .init(
                        get: { selectedBlockchain.isCustomEVM || useCustomEndpoint },
                        set: { useCustomEndpoint = $0 }
                    )

                    TextField("RPC URL", text: displayedRpcUrl)
                        .disabled(!customRPCEnabled.wrappedValue)
                        .padding(.top)

                    Toggle(isOn: customRPCEnabled) {
                        Text("Custom RPC Endpoint")
                    }
                    .disabled(selectedBlockchain.isCustomEVM)
                }

                if keyStore.isWatchOnly {
                    Section {
                        TextField(watchOnlyFieldTitle, text: $address)
                            .disabled(selectedNetwork == nil)
                            .padding(.vertical)
                            .accessibilityIdentifier("add-account-watch-address-field")
                    }
                }
            }
            .padding(.bottom)

            Spacer()

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
        .task(
            id: PathKey(blockchain: pathBlockchain, keyScheme: selectedKeyScheme, scriptType: selectedBitcoinScriptType)
        ) {
            nextDerivationPath = await accountService.nextDerivationPath(
                pathBlockchain,
                keyStore: keyStore,
                signatureScheme: selectedKeyScheme,
                bitcoinScriptType: selectedBitcoinScriptType
            )
        }
        .onChange(of: selectedBlockchain, initial: true) { _, newValue in
            didSelectBlockchain(newValue)
        }
        .onChange(of: selectedNetwork) {
            if case let .evm(network) = selectedNetwork {
                customChainId = "\(network.chainId)"
            } else {
                customChainId = ""
            }
        }
    }
}

// MARK: - Subviews

private extension AddAccountView {
    @ViewBuilder
    var blockchainPicker: some View {
        #if os(macOS)
        // A menu-style `Picker` on macOS ignores `.disabled` on its items,
        // so chains the key store can't use are greyed out via AppKit.
        LabeledContent("Blockchain") {
            BlockchainPopUpButton(
                sections: [standardBlockchains, customEVMBlockchains],
                selection: $selectedBlockchain,
                isEnabled: { $0.isSupported(by: keyStore) }
            )
        }
        #else
        Picker("Blockchain", selection: $selectedBlockchain) {
            ForEach(standardBlockchains, id: \.self) { blockchain in
                Text(blockchain.name).tag(blockchain)
                    .disabled(!blockchain.isSupported(by: keyStore))
            }

            if !customEVMBlockchains.isEmpty {
                Divider()

                ForEach(customEVMBlockchains, id: \.self) { blockchain in
                    Text(blockchain.name).tag(blockchain)
                        .disabled(!blockchain.isSupported(by: keyStore))
                }
            }
        }
        .accessibilityIdentifier("add-account-blockchain-picker")
        #endif
    }

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
                        if case .evm(.custom) = selectedBlockchain {
                            guard let chainId = UInt64(customChainId) else {
                                throw ReefrError.invalidData
                            }

                            try await addAccount(.evm(.custom(chainId)), signatureScheme: selectedKeyScheme)
                        } else {
                            try await addAccount(selectedNetwork!, signatureScheme: selectedKeyScheme)
                        }
                    } catch {
                        self.error = error
                        isAlertPresented = true
                    }
                }
            } label: {
                Text("Add Account")
            }
            .disabled(isAddButtonDisabled)
            .accessibilityIdentifier("add-account-submit-button")
        }
    }
}

// MARK: - Logic

private extension AddAccountView {
    var standardBlockchains: [Blockchain] {
        blockchains.filter { !$0.isCustomEVM }
    }

    var customEVMBlockchains: [Blockchain] {
        blockchains.filter(\.isCustomEVM)
    }

    var isAddButtonDisabled: Bool {
        guard let selectedNetwork else {
            return true
        }

        if keyStore.isWatchOnly, !accountService.isValidAddress(trimmedAddress, for: selectedNetwork) {
            return true
        }

        if useCustomEndpoint, (try? customEndpointURLOverride()) == nil {
            return true
        }

        if derivationPathOverride != nil, !isDerivationPathValid {
            return true
        }

        return false
    }

    var supportsCustomDerivationPath: Bool {
        !keyStore.isWatchOnly
    }

    var isDerivationPathValid: Bool {
        (try? parsedCustomDerivationPath()) != nil
    }

    func parsedCustomDerivationPath() throws -> DerivationPath {
        try DerivationPath(
            string: trimmedDerivationPath,
            for: pathBlockchain,
            curve: selectedKeyScheme ?? (selectedBlockchain.hasKeySchemeChoice ? .ed25519 : nil),
            scriptType: selectedBitcoinScriptType
        )
    }

    /// Bitcoin's coin type depends on the selected network.
    var pathBlockchain: Blockchain {
        if case .bitcoin = selectedBlockchain, let selectedNetwork {
            return selectedNetwork
        }

        return selectedBlockchain
    }

    var trimmedDerivationPath: String {
        customDerivationPath.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `nil` unless the user ticked the override and typed a path.
    var derivationPathOverride: String? {
        guard supportsCustomDerivationPath, useCustomDerivationPath, !trimmedDerivationPath.isEmpty else {
            return nil
        }

        return trimmedDerivationPath
    }

    var trimmedAddress: String {
        address.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var watchOnlyFieldTitle: String {
        if case .cardano = selectedBlockchain {
            return "Cardano Account XPub"
        }

        return "Watch Address"
    }

    @MainActor
    func addAccount(_ blockchain: Blockchain, signatureScheme: Curve?) async throws {
        let watchOnlyAddress = keyStore.isWatchOnly ? trimmedAddress : nil
        let isBitcoin = if case .bitcoin = blockchain { true } else { false }

        let account = try await accountService.makeAccount(
            blockchain,
            keyStore: keyStore,
            rpcURLOverride: try customEndpointURLOverride(),
            signatureScheme: signatureScheme,
            bitcoinScriptType: isBitcoin ? selectedBitcoinScriptType : nil,
            bitcoinBackend: isBitcoin ? selectedBitcoinBackend : nil,
            watchOnlyAddress: watchOnlyAddress,
            derivationPath: derivationPathOverride == nil ? nextDerivationPath : try parsedCustomDerivationPath()
        )

        sidebarSelection.wrappedValue = account.id
        dismiss()
    }

    /// The account's `rpcURLOverride` — `nil` unless the user actually
    /// toggled "Custom RPC Endpoint" on and typed a value. Previously
    /// never passed to `makeAccount` at all, so a custom endpoint (the
    /// only way to point a Bitcoin account at a self-hosted Electrum/
    /// Esplora server rather than the public default) was silently
    /// discarded.
    func customEndpointURLOverride() throws -> URL? {
        guard useCustomEndpoint else {
            return nil
        }

        let trimmedEndpoint = customEndpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEndpoint.isEmpty, let url = URL(string: trimmedEndpoint) else {
            throw ReefrError.invalidData
        }

        return url
    }

    func alertMessage(_ error: Swift.Error?) -> String {
        guard let error else {
            return "Unknown Error."
        }

        switch error {
        case ReefrError.alreadyExists:
            return "AccountModel already exists."
        default:
            return error.localizedDescription
        }
    }

    func didSelectBlockchain(_ blockchain: Blockchain?) {
        if let blockchain {
            networks = blockchain.allNetworks
            selectedNetwork = networks.first

            if blockchain.hasKeySchemeChoice {
                selectedKeyScheme = .ed25519
            } else {
                selectedKeyScheme = nil
            }

            if case let .evm(network) = selectedBlockchain {
                customChainId = "\(network.chainId)"
            } else {
                customChainId = ""
            }
        }
    }
}

private struct PathKey: Hashable {
    let blockchain: Blockchain
    let keyScheme: Curve?
    let scriptType: BitcoinScriptType
}

// MARK: - Blockchain + Key Scheme

private extension Blockchain {
    /// Chains whose accounts may use either Ed25519 or secp256k1.
    var hasKeySchemeChoice: Bool {
        switch self {
        case .aptos, .sui: true
        default: false
        }
    }

    /// Whether accounts on this chain can be created on `keyStore`.
    /// Trezor firmware has no Aptos or Sui support.
    func isSupported(by keyStore: KeyStore) -> Bool {
        switch (keyStore.kind, self) {
        case (.trezor, .aptos), (.trezor, .sui): false
        default: true
        }
    }
}

// MARK: - BlockchainPopUpButton

#if os(macOS)
/// Native pop-up button for the blockchain list, so individual items can be
/// shown disabled. Sections are separated by a divider; empty ones are skipped.
private struct BlockchainPopUpButton: NSViewRepresentable {
    let sections: [[Blockchain]]
    @Binding var selection: Blockchain
    let isEnabled: (Blockchain) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.autoenablesItems = false
        // Draw the collapsed state from our own item (see `collapsedItem(for:)`)
        // instead of the selected menu item.
        (button.cell as? NSPopUpButtonCell)?.usesItemFromMenu = false
        button.target = context.coordinator
        button.action = #selector(Coordinator.didSelect(_:))
        button.setAccessibilityIdentifier("add-account-blockchain-picker")
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self

        guard let menu = button.menu else {
            return
        }

        menu.removeAllItems()

        for section in sections where !section.isEmpty {
            if menu.numberOfItems > 0 {
                menu.addItem(.separator())
            }

            for blockchain in section {
                let item = NSMenuItem(title: blockchain.name, action: nil, keyEquivalent: "")
                item.representedObject = blockchain
                let enabled = isEnabled(blockchain)
                // "Other EVM" has no logo of its own, so it goes without one.
                if !blockchain.isCustomEVM {
                    item.image = Self.menuLogo(named: blockchain.logoImageName, dimmed: !enabled)
                }

                item.isEnabled = enabled
                menu.addItem(item)

                if blockchain == selection {
                    button.select(item)
                }
            }
        }

        (button.cell as? NSPopUpButtonCell)?.menuItem = Self.collapsedItem(for: selection)
    }

    private static let logoSide: CGFloat = 16

    /// Gap added after the logo on the collapsed button; AppKit's own
    /// image-to-title gap there is much tighter than in the open menu.
    private static let collapsedLogoPadding: CGFloat = 4

    /// Opacity of a dimmed logo, roughly matching disabled menu text.
    private static let dimmedLogoOpacity: CGFloat = 0.35

    /// The logo aspect-fitted and centred in a `logoSide` square, followed by
    /// `trailingPadding` of empty space. Drawn into a new image rather than
    /// resizing the shared `NSImage(named:)` instance used elsewhere.
    ///
    /// AppKit only dims template images on disabled items, so a `dimmed`
    /// logo is drawn desaturated and faded here instead.
    private static func menuLogo(
        named name: String,
        trailingPadding: CGFloat = 0,
        dimmed: Bool = false
    ) -> NSImage? {
        guard let logo = NSImage(named: name), logo.size.width > 0, logo.size.height > 0 else {
            return nil
        }

        let side = logoSide
        let scale = min(side / logo.size.width, side / logo.size.height)
        let fitted = NSSize(width: logo.size.width * scale, height: logo.size.height * scale)
        let logoRect = NSRect(
            origin: NSPoint(x: (side - fitted.width) / 2, y: (side - fitted.height) / 2),
            size: fitted
        )

        return NSImage(size: NSSize(width: side + trailingPadding, height: side), flipped: false) { _ in
            guard dimmed, let context = NSGraphicsContext.current?.cgContext else {
                logo.draw(in: logoRect)
                return true
            }

            // Applies to the whole layer when it's composited.
            context.setAlpha(dimmedLogoOpacity)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            logo.draw(in: logoRect)
            // Strip colour but keep luminosity, so the logo's shape stays readable…
            NSColor.gray.setFill()
            logoRect.fill(using: .saturation)
            // …then clip back to the logo's own shape, since the fill also
            // covers its transparent areas.
            logo.draw(in: logoRect, from: .zero, operation: .destinationIn, fraction: 1)
            context.endTransparencyLayer()
            return true
        }
    }

    /// What the collapsed button shows: the selected chain with a padded logo.
    private static func collapsedItem(for blockchain: Blockchain) -> NSMenuItem {
        let item = NSMenuItem(title: blockchain.name, action: nil, keyEquivalent: "")
        if !blockchain.isCustomEVM {
            item.image = menuLogo(named: blockchain.logoImageName, trailingPadding: collapsedLogoPadding)
        }

        return item
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: BlockchainPopUpButton

        init(parent: BlockchainPopUpButton) {
            self.parent = parent
        }

        @objc func didSelect(_ sender: NSPopUpButton) {
            guard let blockchain = sender.selectedItem?.representedObject as? Blockchain else {
                return
            }

            parent.selection = blockchain
        }
    }
}
#endif

// MARK: - BitcoinBackendKind + Display

private extension BitcoinBackendKind {
    var displayName: String {
        switch self {
        case .electrum: "Electrum"
        case .esplora: "Esplora"
        }
    }
}

// MARK: - Preview

#Preview {
    let keyStore = KeyStore(
        deviceId: nil,
        kind: .watchOnly,
        name: "Key Store",
        transport: nil,
        vendor: nil
    )

    AddAccountView(keyStore: keyStore)
        .frame(width: 400)
}
