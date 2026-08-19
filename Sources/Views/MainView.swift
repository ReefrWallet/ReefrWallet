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
    @Query private var allAccounts: [Account]
    @Query private var keyStores: [KeyStore]

    @State private var presentedSheet: PresentedSheet?
    @State private var sidebarSelection: PersistentIdentifier?

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .environment(\.presentSheet, PresentSheetAction(presentedSheet: $presentedSheet))
                .environment(\.sidebarSelection, $sidebarSelection)
        } detail: {
            if let account = allAccounts.first(where: { $0.id == sidebarSelection }) {
                AccountDetailsView(account: account)
            } else if let keyStore = keyStores.first(where: { $0.id == sidebarSelection }) {
                KeyStoreDetailsView(keyStore: keyStore)
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
                if let watchOnlyKeyStore = keyStores.first(where: { $0.kind == .watchOnly }) {
                    AddAccountView(keyStore: watchOnlyKeyStore)
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
