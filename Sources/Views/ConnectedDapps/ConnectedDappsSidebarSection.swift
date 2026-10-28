//
//  ConnectedDappsSidebarSection.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 17.10.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftData
import SwiftUI

private let browserRawKind = ConnectedDappKind.browser.rawValue
private let walletConnectRawKind = ConnectedDappKind.walletConnect.rawValue

/// The sidebar's "Connected dApps" section: browser dapps and the
/// "WalletConnect" entry.
struct ConnectedDappsSidebarSection: View {
    let title: LocalizedStringResource
    var isEditing = false

    @AppStorage("connectedDappsExpanded") private var isExpanded = true
    @State private var isHeaderHovered = false

    @Environment(\.presentSheet) private var presentSheet
    @Environment(\.sidebarSelection) private var sidebarSelection: Binding<PersistentIdentifier?>

    @Query private var accounts: [AccountModel]

    @Query(filter: #Predicate<ConnectedDappModel> { $0.kindRaw == browserRawKind }, sort: \ConnectedDappModel.name)
    private var browserDapps: [ConnectedDappModel]

    @Query(filter: #Predicate<ConnectedDappModel> { $0.kindRaw == walletConnectRawKind })
    private var walletConnectHubs: [ConnectedDappModel]

    private let store = DI.injectOrFail(ConnectedDappStore.self)
    private let walletConnect = DI.injectOrFail(WalletConnectService.self)

    init(_ title: LocalizedStringResource, isEditing: Bool = false) {
        self.title = title
        self.isEditing = isEditing
    }

    /// iPhone rows never show the selection highlight, so never switch to white text.
    private func isHighlighted(_ dapp: ConnectedDappModel) -> Bool {
        !isPhone && sidebarSelection.wrappedValue == dapp.id
    }

    private func remove(_ dapp: ConnectedDappModel) {
        if sidebarSelection.wrappedValue == dapp.id {
            sidebarSelection.wrappedValue = nil
        }

        store.remove(dapp)
    }

    var body: some View {
        Section(isExpanded: $isExpanded) {
            ForEach(browserDapps) { dapp in
                HStack(spacing: isPhone ? 12 : 8) {
                    if isPhone, isEditing {
                        EditModeButton(kind: .remove, accessibilityLabel: .commonRemove) {
                            remove(dapp)
                        }
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    }

                    DappIconView(url: dapp.iconURL)

                    Text(dapp.name)
                        .style(foreground: isHighlighted(dapp) ? .white : .sidebarLabel)
                        .lineLimit(1)
                }
                .tag(dapp.id)
                .phoneRowNeverHighlighted()
                .contextMenu {
                    Button(.commonRemove, role: .destructive) {
                        remove(dapp)
                    }
                }
                .accessibilityIdentifier("sidebar-connected-dapp-\(dapp.host)")
            }

            if isPhone, isEditing {
                EditModeButton(
                    kind: .add,
                    accessibilityLabel: .sidebarAddDappRow,
                    title: .sidebarAddDappRow
                ) {
                    presentSheet?(.addBrowserDapp)
                }
                .phoneRowNeverHighlighted()
                .selectionDisabled()
                .disabled(accounts.isEmpty)
                .sheetSource(PresentedSheet.addBrowserDapp.id)
            }

            if let hub = walletConnectHubs.first, !(isPhone && isEditing) {
                HStack(spacing: 8) {
                    Image("walletConnect16")
                        .style(foreground: .sidebarControl)
                        .frame(width: 20, height: 20)

                    Text(.commonWalletconnect)
                        .style(foreground: isHighlighted(hub) ? .white : .sidebarLabel)

                    Spacer()

                    if !walletConnect.sessions.isEmpty {
                        Text("\(walletConnect.sessions.count)")
                            .style(
                                .small,
                                foreground: isHighlighted(hub) ? .white : .sidebarSecondaryLabel
                            )
                    }

                    if isPhone {
                        Image(systemName: "chevron.right")
                            .style(.smallIcon, foreground: .sidebarSecondaryLabel)
                    }
                }
                .tag(hub.id)
                .phoneRowNeverHighlighted()
                .selectionDisabled(accounts.isEmpty)
                .allowsHitTesting(!accounts.isEmpty)
                .opacity(accounts.isEmpty ? 0.4 : 1)
                .accessibilityIdentifier("sidebar-walletconnect")
            }
        } header: {
            HStack {
                Text(title)
                    .style(isPhone ? .title : nil, foreground: isPhone ? .phoneLabel : .sidebarLabel)

                Spacer()

                if !isPhone {
                    SidebarAddButton(
                        accessibilityLabel: .commonAddDapp,
                        accessibilityId: "sidebar-add-dapp-button",
                        trailingPadding: SidebarAddButton.headerTrailingPadding
                    ) {
                        presentSheet?(.addBrowserDapp)
                    }
                    .disabled(accounts.isEmpty)
                    .opacity(isHeaderHovered ? 1 : 0)
                    .sheetSource(PresentedSheet.addBrowserDapp.id)
                }
            }
            .onHover { isHeaderHovered = $0 }
        }
        .task {
            store.ensureWalletConnectHub()
        }
    }
}
