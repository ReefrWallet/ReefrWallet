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

    @FocusState private var focusedField: Field?
    /// The edited field's value when it gained focus, restored if the new value is invalid.
    @State private var fieldSnapshot = ""

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
        layout
        .alert(.commonError, isPresented: $isAlertPresented) {
            Button(.commonOk) {
                isAlertPresented = false
            }
        } message: {
            Text(verbatim: alertMessage(error))
        }
        .task(
            id: PathKey(blockchain: pathBlockchain, keyScheme: selectedKeyScheme, scriptType: selectedBitcoinScriptType)
        ) {
            let path = await accountService.nextDerivationPath(
                pathBlockchain,
                keyStore: keyStore,
                signatureScheme: selectedKeyScheme,
                bitcoinScriptType: selectedBitcoinScriptType
            )

            // A superseded lookup mustn't overwrite the newer selection's path.
            guard !Task.isCancelled else {
                return
            }

            nextDerivationPath = path
        }
        .onChange(of: selectedBlockchain, initial: true) { _, newValue in
            didSelectBlockchain(newValue)
        }
        .onChange(of: useCustomDerivationPath) { _, isOn in
            if isOn, customDerivationPath.isEmpty {
                customDerivationPath = nextDerivationPath?.string ?? ""
            }
        }
        .onChange(of: useCustomEndpoint) { _, isOn in
            if isOn, customEndpointURL.isEmpty {
                customEndpointURL = defaultRpcUrl
            }
        }
        .onChange(of: focusedField) { oldValue, newValue in
            // Validate the field being left before snapshotting the one being entered.
            if let oldValue {
                validate(oldValue)
            }

            if let newValue {
                fieldSnapshot = value(of: newValue)
            }
        }

        // Interacting with any other control ends editing.
        .onChange(of: useCustomDerivationPath) { focusedField = nil }
        .onChange(of: useCustomEndpoint) { focusedField = nil }
        .onChange(of: selectedBlockchain) { focusedField = nil }
        .onChange(of: selectedNetwork) { focusedField = nil }
        .onChange(of: selectedKeyScheme) { focusedField = nil }
        .onChange(of: selectedBitcoinScriptType) { focusedField = nil }
        .onChange(of: selectedBitcoinBackend) { focusedField = nil }
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
    var layout: some View {
        if isPhone {
            phoneForm
                .phoneSheet(
                    .commonAddAccount,
                    onCancel: { dismiss() },
                    confirmTitle: .commonAdd,
                    confirmId: "add-account-submit-button",
                    isConfirmEnabled: !isAddButtonDisabled,
                    onConfirm: submit
                )
        } else {
            VStack {
                Text(.addAccountAddBlockchainAccount)
                    .style(.largeHeader, foreground: .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom)

                accountForm
                    .padding(.bottom)

                Spacer()

                buttonsView
            }
            .padding()
        }
    }

    var accountForm: some View {
        Form {
            Section {
                blockchainPicker

                if !selectedBlockchain.isCustomEVM {
                    Picker(.addAccountNetwork, selection: $selectedNetwork) {
                        ForEach(networks, id: \.self) { blockchain in
                            Text("\(blockchain.networkName)").tag(blockchain)
                        }
                    }
                    .accessibilityIdentifier("add-account-network-picker")
                }

                if selectedBlockchain.isCustomEVM {
                    TextField(String(localized: .addAccountChainId), text: $customChainId)
                        .disabled(!selectedBlockchain.isCustomEVM)
                } else if selectedBlockchain.hasKeySchemeChoice, !keyStore.isWatchOnly {
                    Picker(.addAccountKeyScheme, selection: $selectedKeyScheme) {
                        ForEach(Curve.allCases, id: \.self) { scheme in
                            Text(verbatim: scheme.description).tag(scheme)
                        }
                    }
                } else if case .bitcoin = selectedBlockchain, !keyStore.isWatchOnly {
                    Picker(.addAccountScriptType, selection: $selectedBitcoinScriptType) {
                        Text(.addAccountNativeSegwit).tag(BitcoinScriptType.p2wpkh)
                        Text(.addAccountTaproot).tag(BitcoinScriptType.p2tr)
                    }
                }

                if case .bitcoin = selectedBlockchain {
                    // Set only here, at account creation — like the RPC
                    // endpoint override below, there is no later
                    // edit-account flow for this yet.
                    Picker(.addAccountBackend, selection: $selectedBitcoinBackend) {
                        ForEach(BitcoinBackendKind.allCases, id: \.self) { backend in
                            Text(verbatim: backend.displayName).tag(backend)
                        }
                    }
                    .accessibilityIdentifier("add-account-bitcoin-backend-picker")
                }
            }

            if supportsCustomDerivationPath {
                Section {
                    TextField(String(localized: .addAccountDerivationPath), text: displayedDerivationPath)
                        .focused($focusedField, equals: .derivationPath)
                        .disabled(!useCustomDerivationPath)
                        .padding(.top)
                        .accessibilityIdentifier("add-account-derivation-path-field")

                    Toggle(.addAccountCustomDerivationPath, isOn: $useCustomDerivationPath)
                        .accessibilityIdentifier("add-account-derivation-path-toggle")
                }
            }

            Section {
                TextField(String(localized: .addAccountRpcUrl), text: displayedRpcUrl)
                    .focused($focusedField, equals: .rpcUrl)
                    .disabled(!customRPCEnabled.wrappedValue)
                    .padding(.top)

                Toggle(isOn: customRPCEnabled) {
                    Text(.addAccountCustomRpcEndpoint)
                }
                .disabled(selectedBlockchain.isCustomEVM)
            }

            if keyStore.isWatchOnly {
                Section {
                    TextField(String(localized: watchOnlyFieldTitle), text: $address)
                        .disabled(selectedNetwork == nil)
                        .padding(.vertical)
                        .accessibilityIdentifier("add-account-watch-address-field")
                } footer: {
                    watchAddressNote
                }
            }
        }
    }

    /// iPhone: label-left / value-right rows; each toggle sits above the field it unlocks.
    var phoneForm: some View {
        Form {
            Section {
                blockchainPicker

                if !selectedBlockchain.isCustomEVM {
                    Picker(.addAccountNetwork, selection: $selectedNetwork) {
                        ForEach(networks, id: \.self) { blockchain in
                            Text("\(blockchain.networkName)").tag(blockchain)
                        }
                    }
                    .accessibilityIdentifier("add-account-network-picker")
                }

                if selectedBlockchain.isCustomEVM {
                    phoneField(.addAccountChainId, text: $customChainId)
                } else if selectedBlockchain.hasKeySchemeChoice, !keyStore.isWatchOnly {
                    Picker(.addAccountKeyScheme, selection: $selectedKeyScheme) {
                        ForEach(Curve.allCases, id: \.self) { scheme in
                            Text(verbatim: scheme.description).tag(scheme)
                        }
                    }
                } else if case .bitcoin = selectedBlockchain, !keyStore.isWatchOnly {
                    Picker(.addAccountScriptType, selection: $selectedBitcoinScriptType) {
                        Text(.addAccountNativeSegwit).tag(BitcoinScriptType.p2wpkh)
                        Text(.addAccountTaproot).tag(BitcoinScriptType.p2tr)
                    }
                }

                if case .bitcoin = selectedBlockchain {
                    Picker(.addAccountBackend, selection: $selectedBitcoinBackend) {
                        ForEach(BitcoinBackendKind.allCases, id: \.self) { backend in
                            Text(verbatim: backend.displayName).tag(backend)
                        }
                    }
                    .accessibilityIdentifier("add-account-bitcoin-backend-picker")
                }
            }

            if supportsCustomDerivationPath {
                Section {
                    Toggle(.addAccountCustomDerivationPath, isOn: $useCustomDerivationPath)
                        .accessibilityIdentifier("add-account-derivation-path-toggle")

                    abbreviatedRow(
                        .addAccountDerivationPath,
                        text: displayedDerivationPath,
                        field: .derivationPath,
                        isEnabled: useCustomDerivationPath
                    )
                    .accessibilityIdentifier("add-account-derivation-path-field")
                }
            }

            Section {
                Toggle(.addAccountCustomRpcEndpoint, isOn: customRPCEnabled)
                    .disabled(selectedBlockchain.isCustomEVM)

                abbreviatedRow(
                    .addAccountRpcUrl,
                    text: displayedRpcUrl,
                    field: .rpcUrl,
                    isEnabled: customRPCEnabled.wrappedValue
                )
            }

            if keyStore.isWatchOnly {
                Section {
                    abbreviatedRow(
                        watchOnlyFieldTitle,
                        text: $address,
                        field: .watchAddress,
                        isEnabled: selectedNetwork != nil
                    )
                    .accessibilityIdentifier("add-account-watch-address-field")
                } footer: {
                    watchAddressNote
                }
            }
        }
        .pickerStyle(.menu)
        .scrollDismissesKeyboard(.immediately)
        .onTouchOutsideTextInput {
            focusedField = nil
        }
    }

    /// Tells EVM users the field also takes an ENS name.
    @ViewBuilder
    var watchAddressNote: some View {
        if case .evm = selectedBlockchain {
            Text(.addAccountWatchAddressNote)
        }
    }

    /// Single-line row: the value is middle-abbreviated until editing starts.
    func abbreviatedRow(
        _ title: LocalizedStringResource,
        text: Binding<String>,
        field: Field,
        isEnabled: Bool
    ) -> some View {
        let isEditing = focusedField == field

        return HStack(spacing: 16) {
            Text(title)
                .foregroundStyle(isEnabled ? .primary : .secondary)

            ZStack(alignment: .trailing) {
                TextField("", text: text)
                    .focused($focusedField, equals: field)
                    .disabled(!isEnabled)
                    .lineLimit(1)
                    .multilineTextAlignment(.trailing)
                    // `.opacity(0)` would make the UIKit field ignore touches.
                    .foregroundStyle(isEditing ? Color.primary : Color.clear)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()

                if !isEditing {
                    Text(verbatim: text.wrappedValue)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(isEnabled ? .primary : .secondary)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    func phoneField(_ title: LocalizedStringResource, text: Binding<String>, field: Field? = nil) -> some View {
        LabeledContent {
            TextField("", text: text)
                .focused($focusedField, equals: field)
                .lineLimit(1)
                .multilineTextAlignment(.trailing)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
        } label: {
            Text(title)
        }
    }

    var customRPCEnabled: Binding<Bool> {
        Binding(
            get: { selectedBlockchain.isCustomEVM || useCustomEndpoint },
            set: { useCustomEndpoint = $0 }
        )
    }

    var displayedDerivationPath: Binding<String> {
        Binding(
            get: {
                useCustomDerivationPath && !customDerivationPath.isEmpty
                    ? customDerivationPath
                    : nextDerivationPath?.string ?? ""
            },
            set: { newValue in
                if useCustomDerivationPath {
                    customDerivationPath = newValue
                }
            }
        )
    }

    var defaultRpcUrl: String {
        if case let .bitcoin(network) = selectedNetwork {
            network.defaultEndpoint(for: selectedBitcoinBackend).absoluteString
        } else {
            selectedNetwork?.rpcURL.absoluteString ?? ""
        }
    }

    var displayedRpcUrl: Binding<String> {
        Binding(
            get: {
                useCustomEndpoint && !customEndpointURL.isEmpty ? customEndpointURL : defaultRpcUrl
            },
            set: { newValue in
                if useCustomEndpoint {
                    customEndpointURL = newValue
                }
            }
        )
    }

    func submit() {
        Task {
            do {
                guard let target = selectedBlockchain.accountTarget(
                    network: selectedNetwork,
                    customChainId: customChainId
                ) else {
                    throw ReefrError.invalidData
                }

                try await addAccount(target, signatureScheme: selectedKeyScheme)
            } catch {
                self.error = error
                isAlertPresented = true
            }
        }
    }

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
        Picker(.addAccountBlockchain, selection: $selectedBlockchain) {
            ForEach(standardBlockchains, id: \.self) { blockchain in
                Text(verbatim: blockchain.name).tag(blockchain)
                    .disabled(!blockchain.isSupported(by: keyStore))
            }

            if !customEVMBlockchains.isEmpty {
                Divider()

                ForEach(customEVMBlockchains, id: \.self) { blockchain in
                    Text(verbatim: blockchain.name).tag(blockchain)
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
                Text(.commonCancel)
            }

            Button {
                submit()
            } label: {
                Text(.commonAddAccount)
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

        if keyStore.isWatchOnly, !isWatchAddressAcceptable(for: selectedNetwork) {
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

    /// An address valid for `network`, or on EVM an ENS name, resolved when the account is added.
    func isWatchAddressAcceptable(for network: Blockchain) -> Bool {
        if accountService.isValidAddress(trimmedAddress, for: network) {
            return true
        }

        if case .evm = network {
            return ENSResolver.isName(trimmedAddress)
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

    /// The chain `submit()` adds to, which next-path numbering is per;
    /// `selectedBlockchain` until a custom chain id parses.
    var pathBlockchain: Blockchain {
        selectedBlockchain.accountTarget(network: selectedNetwork, customChainId: customChainId) ?? selectedBlockchain
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

    var watchOnlyFieldTitle: LocalizedStringResource {
        if case .cardano = selectedBlockchain {
            return .addAccountCardanoAccountXpub
        }

        return .addAccountWatchAddress
    }

    func resolveENSName(_ name: String) async throws -> String {
        do {
            return try await ENSResolver(clientProvider: DI.injectOrFail(BlockchainClientProvider.self))
                .resolve(name)
                .string
        } catch ReefrError.notFound {
            throw FieldError(message: String(localized: .addAccountEnsNotFound))
        }
    }

    @MainActor
    func addAccount(_ blockchain: Blockchain, signatureScheme: Curve?) async throws {
        var watchOnlyAddress = keyStore.isWatchOnly ? trimmedAddress : nil
        var ensName: String?
        if case .evm = blockchain, let name = watchOnlyAddress, ENSResolver.isName(name) {
            watchOnlyAddress = try await resolveENSName(name)
            ensName = name.lowercased()
        }

        let isBitcoin = if case .bitcoin = blockchain { true } else { false }

        let account = try await accountService.makeAccount(
            blockchain,
            keyStore: keyStore,
            rpcURLOverride: try customEndpointURLOverride(),
            signatureScheme: signatureScheme,
            bitcoinScriptType: isBitcoin ? selectedBitcoinScriptType : nil,
            bitcoinBackend: isBitcoin ? selectedBitcoinBackend : nil,
            watchOnlyAddress: watchOnlyAddress,
            accountName: ensName,
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
        guard !trimmedEndpoint.isEmpty,
              let url = URL(string: trimmedEndpoint),
              url.scheme?.isEmpty == false,
              url.host()?.isEmpty == false
        else {
            throw ReefrError.invalidData
        }

        return url
    }

    func value(of field: Field) -> String {
        switch field {
        case .derivationPath: customDerivationPath
        case .rpcUrl: customEndpointURL
        case .watchAddress: address
        }
    }

    /// Alerts and restores the pre-edit value if `field` holds invalid input.
    func validate(_ field: Field) {
        switch field {
        case .derivationPath:
            guard useCustomDerivationPath, !trimmedDerivationPath.isEmpty, !isDerivationPathValid else {
                return
            }

            customDerivationPath = fieldSnapshot
            present(FieldError(message: String(localized: .addAccountInvalidDerivationPath)))

        case .rpcUrl:
            guard useCustomEndpoint, !customEndpointURL.isEmpty, (try? customEndpointURLOverride()) == nil else {
                return
            }

            customEndpointURL = fieldSnapshot
            present(FieldError(message: String(localized: .addAccountInvalidRpcUrl)))

        case .watchAddress:
            break
        }
    }

    func present(_ error: Swift.Error) {
        self.error = error
        isAlertPresented = true
    }

    func alertMessage(_ error: Swift.Error?) -> String {
        guard let error else {
            return String(localized: .commonUnknownError)
        }

        switch error {
        case ReefrError.alreadyExists:
            return String(localized: .addAccountAccountExists)
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

private extension AddAccountView {
    enum Field: Hashable {
        case derivationPath
        case rpcUrl
        case watchAddress
    }
}

private struct FieldError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

private struct PathKey: Hashable {
    let blockchain: Blockchain
    let keyScheme: Curve?
    let scriptType: BitcoinScriptType
}

// MARK: - Blockchain + Account Target

extension Blockchain {
    /// The chain an account is added to when this chain is picked: the typed
    /// id's chain for "Other EVM", else `network`; `nil` if not determined.
    func accountTarget(network: Blockchain?, customChainId: String) -> Blockchain? {
        guard isCustomEVM else {
            return network
        }

        return UInt64(customChainId).map { .evm(.custom($0)) }
    }
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
        case .electrum: String(localized: .addAccountElectrum)
        case .esplora: String(localized: .addAccountEsplora)
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
