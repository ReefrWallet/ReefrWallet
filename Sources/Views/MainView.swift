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

    @State private var presentedSheet: PresentedSheet?
    @State private var sidebarSelection: PersistentIdentifier?

#if os(macOS)
    @Environment(\.openWindow) private var openWindow
#endif

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
                case .walletConnect:
                    WalletConnectSessionsView()
                }
            } else {
                EmptyStateView("No Selection")
                    .task(id: sidebarSelection) {
                        clearInvalidSidebarSelection()
                    }
            }
        }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case let .addAccount(keyStore):
                AddAccountView(keyStore: keyStore)
                    .environment(\.sidebarSelection, $sidebarSelection)
            case .addBrowserDapp:
                AddBrowserDappSheet()
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

            case .browser:
                BrowserView()
            }
        }
        .sheet(item: pendingProposalBinding) { pending in
            WalletConnectProposalSheet(pending: pending)
        }
        .sheet(isPresented: isRequestSheetPresented) {
            if let request = walletConnect.approver.currentRequest {
                DappRequestSheet(request: request) { result in
                    walletConnect.approver.resolve(result)
                }
            }
        }
        .task {
            walletConnect.start()
        }
        .onOpenURL { url in
            sidebarSelection = connectedDapps.first { $0.kind == .walletConnect }?.id
            Task { await walletConnect.pair(uri: url.absoluteString) }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    openBrowser()
                } label: {
                    Label("Browser", systemImage: "globe")
                }
                .accessibilityIdentifier("open-browser-button")
                .accessibilityValue(String(allAccounts.count))
            }
        }
    }
}

private extension MainView {
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

    func openBrowser() {
#if os(macOS)
        openWindow(id: "browser")
#else
        presentedSheet = .browser
#endif
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
