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
    @Query private var keyStores: [KeyStoreModel]

    @State private var presentedSheet: PresentedSheet?
    @State private var sidebarSelection: PersistentIdentifier?

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
            } else {
                Text("No selection")
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
            case .addKeyStore:
                AddKeyStoreView()
                    .environment(\.sidebarSelection, $sidebarSelection)
            case .addWatchOnlyAccount:
                if let watchOnlyKeyStore = keyStores.first(where: { $0.kind == .watchOnly }),
                   let keyStore = try? KeyStore(model: watchOnlyKeyStore) {
                    AddAccountView(keyStore: keyStore)
                        .environment(\.sidebarSelection, $sidebarSelection)
                }
            }
        }
    }
}

private extension MainView {
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

        if !hasSelectedAccount && !hasSelectedKeyStore {
            self.sidebarSelection = nil
        }
    }
}

// MARK: - Preview

#Preview {
    MainView()
}
