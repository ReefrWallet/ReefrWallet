//
//  BrowserAccountSelector.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 02.10.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftData
import SwiftUI

/// The unified browser account control, styled after Xcode's target and
/// run-destination selector. Each key store exposes its own account submenu.
struct BrowserAccountSelector: View {
    let groups: [BrowserAccountSelectionGroup]
    let selectedKeyStoreId: PersistentIdentifier?
    let selectedAccountId: PersistentIdentifier?
    let onSelectAccount: (AccountModel, BrowserAccountSelectionGroup) -> Void

    @State private var isPresented = false
    @State private var presentedKeyStoreId: PersistentIdentifier?

    var body: some View {
        Button {
            presentedKeyStoreId = nil
            isPresented = true
        } label: {
            selectorLabel
        }
        .disabled(!groups.contains { $0.isSelectable })
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            selectorMenu
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("browser-account-selector")
        .accessibilityLabel(accessibilityLabel)
        // macOS toolbars cache the item's accessibility label; a new identity refreshes it.
        .id(selectorTitle)
    }
}

// MARK: - Subviews

private extension BrowserAccountSelector {
    var selectorMenu: some View {
        Group {
            if let group = groups.first(where: { $0.id == presentedKeyStoreId }) {
                accountMenu(for: group)
            } else {
                keyStoreMenu
            }
        }
        .padding(8)
        .frame(minWidth: 220)
    }

    func accountMenuItem(_ account: AccountModel) -> some View {
        HStack {
            Label {
                Text(account.name)
            } icon: {
                account.blockchain.blockchain.logoImage
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16, height: 16)
            }

            if account.id == selectedAccountId {
                Spacer()
                Image(systemName: "checkmark")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    func accountMenu(for group: BrowserAccountSelectionGroup) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                presentedKeyStoreId = nil
            } label: {
                Label(group.name, systemImage: "chevron.left")
            }
            .buttonStyle(.plain)

            ForEach(group.accounts) { account in
                Button {
                    onSelectAccount(account, group)
                    isPresented = false
                } label: {
                    accountMenuItem(account)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("browser-account-menu-item-\(account.name)")
            }
        }
    }

    var keyStoreMenu: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(groups) { group in
                Button {
                    presentedKeyStoreId = group.id
                } label: {
                    HStack {
                        Label(group.name, systemImage: group.kind.systemImage)
                        Spacer()
                        Image(systemName: "chevron.right")
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("browser-key-store-menu-item-\(group.name)")
                .disabled(!group.isSelectable)
            }
        }
    }

    var selectorLabel: some View {
        Label(selectorTitle, systemImage: (displayedGroup?.kind ?? .local).systemImage)
            .labelStyle(.titleAndIcon)
            .style(.medium)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(.quaternary))
    }
}

// MARK: - Logic

private extension BrowserAccountSelector {
    var accessibilityLabel: String {
        "\(displayedGroup?.name ?? "No Key Store"), \(displayedAccount?.name ?? "No Account")"
    }

    var displayedAccount: AccountModel? {
        selectedAccount ?? displayedGroup?.accounts.first
    }

    var displayedGroup: BrowserAccountSelectionGroup? {
        selectedGroup ?? groups.first(where: \.isSelectable)
    }

    var selectorTitle: String {
        "\(displayedGroup?.name ?? "No Key Store")  ›  \(displayedAccount?.name ?? "No Account")"
    }

    var selectedAccount: AccountModel? {
        selectedGroup?.accounts.first { $0.id == selectedAccountId }
    }

    var selectedGroup: BrowserAccountSelectionGroup? {
        groups.first { $0.id == selectedKeyStoreId }
    }
}

// MARK: - KeyStore.Kind

private extension KeyStore.Kind {
    var systemImage: String {
        switch self {
        case .local: "desktopcomputer"
        case .trezor: "key.fill"
        case .watchOnly: "eye"
        }
    }
}
