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
            } else if sidebarSelection == nil {
                Text("No selection")
            } else {
                preconditionFailure()
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

// MARK: - Preview

#Preview {
    MainView()
}
