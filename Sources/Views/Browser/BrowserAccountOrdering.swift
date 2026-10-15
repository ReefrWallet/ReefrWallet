//
//  BrowserAccountOrdering.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 02.10.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftData

/// One selectable row in the key-store region of
/// ``BrowserAccountSelector`` — a regular key store, or the single
/// flattened "Watch-only Accounts" group.
struct BrowserAccountSelectionGroup: Identifiable, Equatable {
    let id: PersistentIdentifier
    let name: String
    /// The underlying key store's kind — `.watchOnly` for the flattened
    /// "Watch-only Accounts" group — so the selector can show a
    /// key/device/watch icon without re-deriving it from the name.
    let kind: KeyStore.Kind
    /// Already filtered to browser-supported chains (see
    /// ``DappNamespace/namespace(for:)``) and, for regular key stores,
    /// already sorted the same way `SidebarView` orders its accounts.
    let accounts: [AccountModel]

    var isSelectable: Bool { !accounts.isEmpty }
}

/// Builds the unified selector's `[ Key Store ] › [ Blockchain Account ]`
/// hierarchy directly from `KeyStoreModel`, so a key store with zero
/// browser-supported accounts still appears (disabled) rather than being
/// silently dropped.
enum BrowserAccountOrdering {
    /// Hardware → Local → Watch-only Accounts, matching `SidebarView`'s
    /// section order. Regular key stores are sorted by `(kind, name)`;
    /// the watch-only group is unsorted, matching `SidebarView`'s own
    /// unsorted treatment of `watchOnlyKeyStore.accounts`.
    static func groups(from keyStores: [KeyStoreModel]) -> [BrowserAccountSelectionGroup] {
        groups(from: keyStores, accounts: keyStores.flatMap(\.accounts))
    }

    /// Uses the separately observed account query when building browser UI.
    /// SwiftData may publish a new account before refreshing a key store's
    /// relationship collection in another window scene.
    static func groups(
        from keyStores: [KeyStoreModel],
        accounts accountModels: [AccountModel]
    ) -> [BrowserAccountSelectionGroup] {
        let regularGroups = keyStores
            .filter { !$0.isWatchOnly }
            .sorted { ($0.kind, $0.name) < ($1.kind, $1.name) }
            .map { keyStore in
                BrowserAccountSelectionGroup(
                    id: keyStore.id,
                    name: keyStore.name,
                    kind: keyStore.kind,
                    accounts: supportedAccounts(in: accounts(for: keyStore, from: accountModels)).sorted()
                )
            }

        guard
            let watchOnlyKeyStore = keyStores.first(where: \.isWatchOnly),
            !accounts(for: watchOnlyKeyStore, from: accountModels).isEmpty
        else {
            return regularGroups
        }

        let watchOnlyGroup = BrowserAccountSelectionGroup(
            id: watchOnlyKeyStore.id,
            name: "Watch-only Accounts",
            kind: .watchOnly,
            accounts: supportedAccounts(in: accounts(for: watchOnlyKeyStore, from: accountModels))
        )

        return regularGroups + [watchOnlyGroup]
    }

    private static func supportedAccounts(in accounts: [AccountModel]) -> [AccountModel] {
        accounts.filter { DappNamespace.namespace(for: $0.blockchain.blockchain) != nil }
    }

    private static func accounts(for keyStore: KeyStoreModel, from accounts: [AccountModel]) -> [AccountModel] {
        accounts.filter { $0.keyStore.id == keyStore.id }
    }
}
