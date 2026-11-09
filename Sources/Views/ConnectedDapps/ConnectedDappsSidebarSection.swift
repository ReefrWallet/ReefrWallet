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

    /// Mirrors the stored value; `@AppStorage` updates arrive outside the toggle's animation.
    @State private var isExpanded: Bool
    @AppStorage("connectedDappsExpanded") private var storedExpanded = true

    @Environment(\.presentSheet) private var presentSheet
    @Environment(\.sidebarSelection) private var sidebarSelection: Binding<PersistentIdentifier?>

    let hasAccounts: Bool

    @Query(filter: #Predicate<ConnectedDappModel> { $0.kindRaw == browserRawKind }, sort: \ConnectedDappModel.name)
    private var browserDapps: [ConnectedDappModel]

    @Query(filter: #Predicate<ConnectedDappModel> { $0.kindRaw == walletConnectRawKind })
    private var walletConnectHubs: [ConnectedDappModel]

    private let store = DI.injectOrFail(ConnectedDappStore.self)
    private let walletConnect = DI.injectOrFail(WalletConnectService.self)

    init(_ title: LocalizedStringResource, hasAccounts: Bool, isEditing: Bool = false) {
        self.title = title
        self.hasAccounts = hasAccounts
        self.isEditing = isEditing
        let isExpanded = UserDefaults.standard.object(forKey: "connectedDappsExpanded") as? Bool ?? true
        _isExpanded = State(initialValue: isExpanded)
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
        SidebarSection(isExpanded: $isExpanded) {
            SidebarAddButton(
                accessibilityLabel: .commonAddDapp,
                accessibilityId: "sidebar-add-dapp-button",
                systemImage: "link.badge.plus",
                trailingPadding: 0
            ) {
                presentSheet?(.addBrowserDapp)
            }
            .disabled(!hasAccounts)
            .sheetSource(PresentedSheet.addBrowserDapp.id)
        } content: {
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
                .disabled(!hasAccounts)
                .sheetSource(PresentedSheet.addBrowserDapp.id)
            }

            if let hub = walletConnectHubs.first, !(isPhone && isEditing) {
                HStack(spacing: isPhone ? 12 : 8) {
                    Image("walletConnect16")
                        .style(foreground: .sidebarControl)
                        .frame(width: 20, height: 20)

                    Text(.commonWalletconnect)
                        .style(foreground: isHighlighted(hub) ? .white : .sidebarLabel)

                    Spacer()

                    if !walletConnect.sessions.isEmpty {
                        Text("\(walletConnect.sessions.count)")
                            .style(
                                isPhone ? .large : .small,
                                foreground: isPhone
                                    ? .phoneSecondaryLabel
                                    : isHighlighted(hub) ? .white : .sidebarSecondaryLabel
                            )
                    }

                    if isPhone {
                        Image(systemName: "chevron.right")
                            .style(.smallIcon, foreground: .phoneSecondaryLabel)
                    }
                }
                .tag(hub.id)
                .phoneRowNeverHighlighted()
                .selectionDisabled(!hasAccounts)
                .allowsHitTesting(hasAccounts)
                .opacity(hasAccounts ? 1 : 0.4)
                .accessibilityIdentifier("sidebar-walletconnect")
            }
        } title: {
            Text(title)
                .style(isPhone ? .title : nil, foreground: isPhone ? .phoneLabel : .sidebarLabel)
        } trailing: {
            EmptyView()
        }
        .onChange(of: isExpanded) {
            storedExpanded = isExpanded
        }
        .task {
            store.ensureWalletConnectHub()
        }
    }
}
