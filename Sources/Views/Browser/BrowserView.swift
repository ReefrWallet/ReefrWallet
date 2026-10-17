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
                AptosDappProvider(), EthereumDappProvider(), SolanaDappProvider(), SuiDappProvider(), TronDappProvider()
            ],
            session: session,
            approving: approver,
            signingService: signingService
        )

        self.approver = approver
        self.session = session
        webViewController = DappWebViewController(bridge: bridge)
        selectionModel = BrowserAccountSelectionModel(session: session) {
            Task { await bridge.sessionDidChange() }
        }

        Task { await session.restorePermissions() }
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

#if os(macOS)
    @Environment(\.dismissWindow) private var dismissWindow
#endif

    @State private var addressText: String
    @State private var controller: BrowserController

    private let initialURL: URL

    init(initialURL: URL = URL(string: "https://app.uniswap.org")!) {
        self.initialURL = initialURL
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

                controller.selectionModel.reconcile(groups: groups)
            }
            .task(id: accountModels.count) {
                controller.selectionModel.reconcile(groups: groups)
            }
            .onChange(of: keyStoreModels) {
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
                    DappRequestSheet(request: request) { result in
                        controller.approver.resolve(result)
                    }
                }
            }
            .alert(
                "Request Failed",
                isPresented: isFailureAlertPresented,
                presenting: controller.approver.failureMessage
            ) { _ in
                Button("OK") {}
            } message: { message in
                Text(message)
            }
    }
}

// MARK: - Subviews

private extension BrowserView {
    @ToolbarContentBuilder
    var navigationButtons: some ToolbarContent {
        ToolbarItem {
            Button {
                controller.webViewController.goBack()
            } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .disabled(!controller.webViewController.canGoBack)
        }

        ToolbarItem {
            Button {
                controller.webViewController.goForward()
            } label: {
                Label("Forward", systemImage: "chevron.right")
            }
            .disabled(!controller.webViewController.canGoForward)
        }

        ToolbarItem {
            Button {
                controller.webViewController.reload()
            } label: {
                Label("Reload", systemImage: "arrow.clockwise")
            }
        }
    }

    @ToolbarContentBuilder
    var addressField: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            TextField("Address", text: $addressText)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 320)
                .onSubmit {
                    controller.webViewController.load(addressText)
                }
                .accessibilityIdentifier("browser-address-field")
        }
    }

    @ToolbarContentBuilder
    var accountSelector: some ToolbarContent {
        ToolbarItem {
            BrowserAccountSelector(
                groups: groups,
                selectedKeyStoreId: controller.selectionModel.selectedKeyStoreId,
                selectedAccountId: controller.selectionModel.selectedAccountId,
                onSelectAccount: { account, group in
                    controller.selectionModel.select(account, in: group)
                }
            )
        }

#if os(macOS)
        ToolbarItem {
            Button {
                dismissWindow(id: "browser", value: initialURL)
            } label: {
                Label("Close Browser", systemImage: "xmark")
            }
            .accessibilityIdentifier("browser-close-button")
        }
#endif
    }
}

// MARK: - Logic

private extension BrowserView {
    var groups: [BrowserAccountSelectionGroup] {
        BrowserAccountOrdering.groups(from: keyStoreModels, accounts: accountModels)
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
