//
//  MainView.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 28.12.25.
//  Copyright © 2025 Reefr Wallet. All rights reserved.
//

import SwiftData
import SwiftUI

// MARK: - PresentSheetAction

struct PresentSheetAction {
    var presentedSheet: Binding<PresentedSheet?>

    func callAsFunction(_ sheet: PresentedSheet) {
        presentedSheet.wrappedValue = sheet
    }
}

// MARK: - MainView

extension EnvironmentValues {
    @Entry var presentSheet: PresentSheetAction?
    @Entry var sidebarSelection: Binding<PersistentIdentifier?> = .constant(nil)
}

struct MainView: View {
    @Query private var allAccounts: [AccountModel]
    @Query private var connectedDapps: [ConnectedDappModel]
    @Query private var keyStores: [KeyStoreModel]

    @Namespace private var sheetNamespace

    @State private var presentedSheet: PresentedSheet?
    @State private var sidebarSelection: PersistentIdentifier?

    private let walletConnect = DI.injectOrFail(WalletConnectService.self)

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .environment(\.presentSheet, PresentSheetAction(presentedSheet: $presentedSheet))
                .environment(\.sidebarSelection, $sidebarSelection)
        } detail: {
            if let accountModel = allAccounts.first(where: { $0.id == sidebarSelection }),
               let account = try? Account(model: accountModel),
               let keyStore = try? KeyStore(model: accountModel.keyStore) {
                AccountDetailsView(account, keyStore: keyStore)
            } else if let keyStoreModel = keyStores.first(where: { $0.id == sidebarSelection }),
                      let keyStore = try? KeyStore(model: keyStoreModel) {
                KeyStoreDetailsView(keyStore)
            } else if let dapp = connectedDapps.first(where: { $0.id == sidebarSelection }) {
                switch dapp.kind {
                case .browser:
                    BrowserDappDetailsView(dapp: dapp)
                        .environment(\.presentSheet, PresentSheetAction(presentedSheet: $presentedSheet))
                case .walletConnect:
                    WalletConnectSessionsView()
                }
            } else {
                EmptyStateView(.mainNoSelection)
                    .task(id: sidebarSelection) {
                        clearInvalidSidebarSelection()
                    }
            }
        }
        .environment(\.sheetNamespace, sheetNamespace)
        .sheet(item: $presentedSheet) { sheet in
            Group {
                switch sheet {
                case let .addAccount(keyStore):
                    AddAccountView(keyStore: keyStore)
                        .environment(\.sidebarSelection, $sidebarSelection)
                case .addBrowserDapp:
                    AddBrowserDappSheet()
                        .environment(\.presentSheet, PresentSheetAction(presentedSheet: $presentedSheet))
                        .environment(\.sidebarSelection, $sidebarSelection)
                case .addKeyStore:
                    AddKeyStoreView()
                        .environment(\.sidebarSelection, $sidebarSelection)
                case .addWatchOnlyAccount:
                    if let watchOnlyKeyStore = keyStores.first(where: { $0.kind == .watchOnly }),
                       let keyStore = try? KeyStore(model: watchOnlyKeyStore) {
                        AddAccountView(keyStore: keyStore)
                            .environment(\.sidebarSelection, $sidebarSelection)
                    }

                case let .backUpKeyStore(keyStore):
                    BackupKeyStoreView(keyStore: keyStore)

                case let .browser(url):
#if os(iOS)
                    NavigationStack {
                        BrowserView(initialURL: url)
                            .navigationBarTitleDisplayMode(.inline)
                    }
#else
                    BrowserView(initialURL: url)
#endif

                case .settings:
                    SettingsView()
                }
            }
            .hardwareKeyPromptHost()
            .sheetZoom(from: sheet.id, namespace: sheetNamespace)
        }
        .sheet(item: pendingProposalBinding) { pending in
            WalletConnectProposalSheet(pending: pending)
        }
        .sheet(isPresented: isRequestSheetPresented) {
            if let request = walletConnect.approver.currentRequest {
                DappRequestSheet(
                    request: request,
                    isProcessing: walletConnect.approver.isProcessing
                ) { result, keepsPresented in
                    walletConnect.approver.resolve(result, keepsPresented: keepsPresented)
                }
                .hardwareKeyPromptHost(progress: walletConnect.approver.progressPrompt)
            }
        }
        .hardwareKeyPromptHost()
        .alert(
            .commonRequestFailed,
            isPresented: isFailureAlertPresented,
            presenting: walletConnect.approver.failureMessage
        ) { _ in
            Button(.commonOk) {}
        } message: { message in
            Text(message)
        }
        .task {
            walletConnect.start()
        }
        .onOpenURL { url in
            sidebarSelection = connectedDapps.first { $0.kind == .walletConnect }?.id
            Task { await walletConnect.pair(uri: url.absoluteString) }
        }
    }
}

private extension MainView {
    var isFailureAlertPresented: Binding<Bool> {
        Binding(
            get: { walletConnect.approver.failureMessage != nil && walletConnect.approver.currentRequest == nil },
            set: { isPresented in
                if !isPresented {
                    walletConnect.approver.failureMessage = nil
                }
            }
        )
    }

    var isRequestSheetPresented: Binding<Bool> {
        Binding(
            get: { walletConnect.approver.currentRequest != nil },
            set: { if !$0 { walletConnect.approver.rejectPending() } }
        )
    }

    var pendingProposalBinding: Binding<WalletConnectPendingProposal?> {
        Binding(
            get: { walletConnect.pendingProposal },
            set: { newValue in
                if newValue == nil, walletConnect.pendingProposal != nil {
                    Task { await walletConnect.rejectProposal() }
                }
            }
        )
    }

    @MainActor
    func clearInvalidSidebarSelection() {
        guard let sidebarSelection else {
            return
        }

        let hasSelectedAccount = allAccounts.contains { accountModel in
            accountModel.id == sidebarSelection
                && (try? Account(model: accountModel)) != nil
                && (try? KeyStore(model: accountModel.keyStore)) != nil
        }

        let hasSelectedKeyStore = keyStores.contains { keyStoreModel in
            keyStoreModel.id == sidebarSelection
                && (try? KeyStore(model: keyStoreModel)) != nil
        }

        let hasSelectedDapp = connectedDapps.contains { $0.id == sidebarSelection }

        if !hasSelectedAccount && !hasSelectedKeyStore && !hasSelectedDapp {
            self.sidebarSelection = nil
        }
    }
}

// MARK: - Preview

#Preview {
    MainView()
}
