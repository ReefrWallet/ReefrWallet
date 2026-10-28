//
//  BrowserView.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 25.09.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftData
import SwiftUI
import WalletKit

/// What a browser window shows: a dapp, and optionally the chain it was opened
/// for. Each combination gets its own window, so one dapp can be open on
/// several chains at once.
struct BrowserWindowTarget: Codable, Hashable {
    let url: URL
    var namespace: String?

    init(url: URL, namespace: DappNamespace? = nil) {
        self.url = url
        self.namespace = namespace?.rawValue
    }
}

/// One browser tab's bag of dependencies — the ``DappSession``,
/// ``DappApprover``, ``DappBridge``/``DappWebViewController`` pair, and
/// the unified selector's ``BrowserAccountSelectionModel`` — bundled into
/// a single `@Observable` reference so `BrowserView` can keep it alive in
/// one `@State` across body re-evaluations.
@MainActor
@Observable
private final class BrowserController {
    let approver: DappApprover
    let session: DappSession
    let webViewController: DappWebViewController
    let selectionModel: BrowserAccountSelectionModel

    init(initialURL: URL) {
        let approver = DappApprover()
        let session = DappSession(
            origin: Self.origin(for: initialURL), persistence: DI.injectOrFail(ConnectedDappStore.self)
        )

        let signingService = DI.injectOrFail(DappSigningService.self)
        let bridge = DappBridge(
            providers: [
                AptosDappProvider(), CardanoDappProvider(), EthereumDappProvider(), SolanaDappProvider(),
                SuiDappProvider(), TronDappProvider()
            ],
            session: session,
            approving: approver,
            signingService: signingService,
            accounts: DatabaseDappAccountSource()
        )

        self.approver = approver
        self.session = session
        webViewController = DappWebViewController(bridge: bridge)
        selectionModel = BrowserAccountSelectionModel(session: session) {
            Task { await bridge.sessionDidChange() }
        }

        Task { await session.restorePermissions() }
    }

    /// Picks up connections changed from the dapp's settings, then reloads the page.
    func reload(groups: [BrowserAccountSelectionGroup], namespace: DappNamespace?) async {
        await session.reloadPermissions()
        await selectRememberedAccount(groups: groups, namespace: namespace, after: nil)
        await webViewController.bridge.sessionDidChange()
        webViewController.reload()
    }

    /// Makes every chain the dapp was connected on available to it again,
    /// whichever account the toolbar shows.
    private func restoreConnections() async {
        let source = DatabaseDappAccountSource()

        for namespace in DappNamespace.allCases {
            guard
                let address = await session.grantedAddress(namespace),
                let choice = await source.choices(for: namespace).first(where: { $0.account.address == address })
            else {
                continue
            }

            await session.rememberConnection(namespace, account: choice.account)
        }
    }

    /// Selects the account this dapp was last connected with, so reopening it
    /// shows (and signs with) the wallet it remembers rather than the default.
    func selectRememberedAccount(
        groups: [BrowserAccountSelectionGroup],
        namespace: DappNamespace?,
        after pick: Task<Void, Never>?
    ) async {
        await pick?.value
        await session.restorePermissions()
        await restoreConnections()

        // A window opened for one chain starts on that chain's account.
        let remembered: String?
        if let namespace, let address = await session.grantedAddress(namespace) {
            remembered = address
        } else {
            remembered = await session.rememberedAddress()
        }

        guard let address = remembered else {
            return
        }

        for group in groups {
            guard let model = group.accounts.first(where: { $0.address == address }) else {
                continue
            }

            await selectionModel.select(model, in: group)?.value
            return
        }
    }

    /// Matches `DappBridge`'s own `WKSecurityOrigin`-derived origin string
    /// (`"\(protocol)://\(host):\(port)"`) so the very first dispatch on a
    /// freshly opened window sees an *unchanged* origin — avoiding a
    /// spurious permission-clearing `sessionDidChange` notification
    /// before the dapp has made any request at all.
    private static func origin(for url: URL) -> String {
        "\(url.scheme ?? "")://\(url.host ?? ""):\(url.port ?? 0)"
    }
}

// MARK: - BrowserView

@MainActor
struct BrowserView {
    @Query private var accountModels: [AccountModel]
    @Query private var keyStoreModels: [KeyStoreModel]
    @Query private var connectedDapps: [ConnectedDappModel]

#if os(macOS)
    @Environment(\.dismissWindow) private var dismissWindow
#else
    @Environment(\.dismiss) private var dismiss
#endif

    @State private var addressText: String
    @State private var controller: BrowserController

    private let initialURL: URL
    private let namespace: DappNamespace?

    init(initialURL: URL = URL(string: "https://app.uniswap.org")!, namespace: DappNamespace? = nil) {
        self.initialURL = initialURL
        self.namespace = namespace
        _addressText = State(initialValue: initialURL.absoluteString)
        _controller = State(initialValue: BrowserController(initialURL: initialURL))
    }
}

// MARK: - View

extension BrowserView: View {
    var body: some View {
        DappWebView(controller: controller.webViewController, initialURL: initialURL)
            .onChange(of: controller.webViewController.currentURLString) { _, newValue in
                addressText = newValue
            }
            .task {
                controller.webViewController.bridge.onProviderDrivenAccountChange = { account in
                    controller.selectionModel.syncFromProviderDrivenChange(account, groups: groups)
                }

                let pick = controller.selectionModel.reconcile(groups: groups)
                await controller.selectRememberedAccount(groups: groups, namespace: namespace, after: pick)
            }
            .task(id: accountModels.count) {
                controller.selectionModel.reconcile(groups: groups)
            }
            .onChange(of: keyStoreModels) {
                controller.selectionModel.reconcile(groups: groups)
            }
            .onChange(of: supportedNamespaces) {
                controller.selectionModel.reconcile(groups: groups)
            }
            .onDisappear {
                // Closing the window dismisses the approval sheet without going
                // through its buttons or the sheet binding below.
                controller.approver.rejectPending()
            }
            .toolbar {
                navigationButtons
                addressField
                accountSelector
            }
            .sheet(isPresented: isApprovalSheetPresented) {
                if let request = controller.approver.currentRequest {
                    DappRequestSheet(
                        request: request,
                        isProcessing: controller.approver.isProcessing
                    ) { result, keepsPresented in
                        controller.approver.resolve(result, keepsPresented: keepsPresented)
                    } onChooseAccounts: { accounts in
                        controller.approver.resolveAccountChoices(accounts)
                    }
                    .hardwareKeyPromptHost(progress: controller.approver.progressPrompt)
                }
            }
            .hardwareKeyPromptHost()
            .alert(
                .commonRequestFailed,
                isPresented: isFailureAlertPresented,
                presenting: controller.approver.failureMessage
            ) { _ in
                Button(.commonOk) {}
            } message: { message in
                Text(message)
            }
    }
}

// MARK: - Subviews

private extension BrowserView {
    @ToolbarContentBuilder
    var navigationButtons: some ToolbarContent {
#if os(macOS)
        let placement = ToolbarItemPlacement.automatic
#else
        let placement = ToolbarItemPlacement.bottomBar
#endif

        ToolbarItem(placement: placement) {
            Button {
                controller.webViewController.goBack()
            } label: {
                Label(.commonBack, systemImage: "chevron.left")
            }
            .disabled(!controller.webViewController.canGoBack)
        }

        ToolbarItem(placement: placement) {
            Button {
                controller.webViewController.goForward()
            } label: {
                Label(.browserForward, systemImage: "chevron.right")
            }
            .disabled(!controller.webViewController.canGoForward)
        }

        ToolbarItem(placement: placement) {
            Button {
                Task { await controller.reload(groups: groups, namespace: namespace) }
            } label: {
                Label(.browserReload, systemImage: "arrow.clockwise")
            }
        }
    }

    @ToolbarContentBuilder
    var addressField: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Text(addressText)
                .style(.small, foreground: .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(minWidth: 320)
                .accessibilityIdentifier("browser-address-field")
        }
    }

    @ToolbarContentBuilder
    var accountSelector: some ToolbarContent {
        ToolbarItem {
            BrowserAccountSelector(connected: connectedAccounts)
        }

#if os(macOS)
        ToolbarItem {
            Button {
                dismissWindow(id: "browser", value: BrowserWindowTarget(url: initialURL, namespace: namespace))
            } label: {
                Label(.browserCloseBrowser, systemImage: "xmark")
            }
            .accessibilityIdentifier("browser-close-button")
        }
#else
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                dismiss()
            } label: {
                Label(.browserCloseBrowser, systemImage: "xmark")
            }
            .accessibilityIdentifier("browser-close-button")
        }
#endif
    }
}

// MARK: - Logic

private extension BrowserView {
    /// The accounts the drop-down offers: those on blockchains the current site
    /// has asked to connect on, or every browser-supported account until it has.
    var groups: [BrowserAccountSelectionGroup] {
        let groups = BrowserAccountOrdering.groups(from: keyStoreModels, accounts: accountModels)
        guard !supportedNamespaces.isEmpty else {
            return groups
        }

        return groups.map { group in
            BrowserAccountSelectionGroup(
                id: group.id,
                name: group.name,
                kind: group.kind,
                accounts: group.accounts.filter { model in
                    DappNamespace.namespace(for: model.blockchain.blockchain).map(supportedNamespaces.contains) ?? false
                }
            )
        }
    }

    /// The accounts the site on screen is connected with, one per chain.
    var connectedAccounts: [DappAccountChoice] {
        guard let dapp = currentDapp else {
            return []
        }

        let names = Dictionary(uniqueKeysWithValues: keyStoreModels.map { ($0.id, $0.name) })
        let addresses = Set(dapp.grants.map(\.accountAddress))

        return accountModels
            .compactMap { model -> DappAccountChoice? in
                guard addresses.contains(model.address), let account = try? Account(model: model) else {
                    return nil
                }

                return DappAccountChoice(account: account, keyStoreName: names[account.keyStoreId] ?? "")
            }
            .sorted { $0.account.blockchain.displayName < $1.account.blockchain.displayName }
    }

    /// The saved entry for the site on screen.
    var currentDapp: ConnectedDappModel? {
        guard let url = URL(string: controller.webViewController.currentURLString) else {
            return nil
        }

        return connectedDapps.first { $0.kind == .browser && $0.origin == ConnectedDappStore.origin(for: url) }
    }

    /// The chains the current site has asked to connect on or holds a grant for.
    var supportedNamespaces: Set<DappNamespace> {
        guard let dapp = currentDapp else {
            return []
        }

        return Set((dapp.requestedNamespaces + dapp.grants.map(\.namespace)).compactMap(DappNamespace.init(rawValue:)))
    }

    var isApprovalSheetPresented: Binding<Bool> {
        Binding(
            get: { controller.approver.currentRequest != nil },
            set: { isPresented in
                if !isPresented {
                    controller.approver.resolve(.rejected)
                }
            }
        )
    }

    var isFailureAlertPresented: Binding<Bool> {
        Binding(
            get: { controller.approver.failureMessage != nil && controller.approver.currentRequest == nil },
            set: { isPresented in
                if !isPresented {
                    controller.approver.failureMessage = nil
                }
            }
        )
    }
}
