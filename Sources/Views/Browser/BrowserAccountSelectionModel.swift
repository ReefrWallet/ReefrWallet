//
//  BrowserAccountSelectionModel.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 02.10.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Observation
import SwiftData

/// Bridges synchronous SwiftUI rendering with the actor-isolated
/// ``DappSession`` — owns the unified selector's displayed identifiers,
/// reconciling them against `@Query`-published `KeyStoreModel`s and
/// writing user-driven selections back into the session.
@MainActor
@Observable
final class BrowserAccountSelectionModel {
    private(set) var selectedKeyStoreId: PersistentIdentifier?
    private(set) var selectedAccountId: PersistentIdentifier?

    private let session: DappSession
    private let notifyBridge: () -> Void

    init(session: DappSession, notifyBridge: @escaping () -> Void) {
        self.session = session
        self.notifyBridge = notifyBridge
    }

    /// Picks a default only when nothing is selected yet, or the current
    /// selection no longer exists in `groups` (e.g. its account was
    /// deleted) — never re-picks "first" just because `@Query` republished
    /// the same data. Notifies the bridge when it replaces or clears an
    /// existing selection (a real account change), but stays silent for
    /// the very first default pick. Returns the spawned session-mutating
    /// task — `nil` when nothing changed — so tests can await it
    /// deterministically; callers that fire-and-forget can ignore it.
    ///
    /// Goes through ``DappSession/replaceActiveAccount(_:)``, not
    /// `setActiveAccount`: this pick is the app's, so a connected origin's
    /// grant must not follow it onto an account the user never approved.
    @discardableResult
    func reconcile(groups: [BrowserAccountSelectionGroup]) -> Task<Void, Never>? {
        let selectedGroup = groups.first { $0.id == selectedKeyStoreId }
        if let selectedGroup, selectedGroup.accounts.contains(where: { $0.id == selectedAccountId }) {
            return nil
        }

        let hadSelection = selectedAccountId != nil

        guard
            let fallbackGroup = groups.first(where: \.isSelectable),
            let fallbackAccount = fallbackGroup.accounts.first
        else {
            selectedKeyStoreId = nil
            selectedAccountId = nil

            guard hadSelection else {
                return nil
            }

            return Task {
                await session.clearActiveAccount()
                notifyBridge()
            }
        }

        selectedKeyStoreId = fallbackGroup.id
        selectedAccountId = fallbackAccount.id

        return Task {
            guard let account = try? Account(model: fallbackAccount) else {
                return
            }

            await session.replaceActiveAccount(account)
            if hadSelection {
                notifyBridge()
            }
        }
    }

    /// Switches to `group`'s first account — a no-op if `group` is
    /// already selected, per the spec's "keep the selected account if it
    /// belongs to that key store" rule.
    @discardableResult
    func selectKeyStore(_ group: BrowserAccountSelectionGroup) -> Task<Void, Never>? {
        guard group.id != selectedKeyStoreId, let firstAccount = group.accounts.first else {
            return nil
        }

        selectedKeyStoreId = group.id
        selectedAccountId = firstAccount.id

        return Task {
            guard let account = try? Account(model: firstAccount) else {
                return
            }

            await session.setActiveAccount(account)
            notifyBridge()
        }
    }

    @discardableResult
    func select(_ accountModel: AccountModel, in group: BrowserAccountSelectionGroup) -> Task<Void, Never>? {
        guard
            group.accounts.contains(where: { $0.id == accountModel.id }),
            selectedKeyStoreId != group.id || selectedAccountId != accountModel.id
        else {
            return nil
        }

        selectedKeyStoreId = group.id
        selectedAccountId = accountModel.id

        return Task {
            guard let account = try? Account(model: accountModel) else {
                return
            }

            await session.setActiveAccount(account)
            notifyBridge()
        }
    }

    /// Mirrors a provider-driven switch (e.g. `wallet_switchEthereumChain`)
    /// into the displayed identifiers. Only updates local state — never
    /// calls `session.setActiveAccount`, which would re-enter the
    /// dispatch-driven mutation that triggered this call in the first
    /// place (see `DappBridge.onProviderDrivenAccountChange`'s doc comment).
    func syncFromProviderDrivenChange(_ account: Account?, groups: [BrowserAccountSelectionGroup]) {
        guard let account else {
            selectedKeyStoreId = nil
            selectedAccountId = nil
            return
        }

        for group in groups {
            guard let matchedAccount = group.accounts.first(where: { $0.id == account.id }) else {
                continue
            }

            selectedKeyStoreId = group.id
            selectedAccountId = matchedAccount.id
            return
        }
    }
}
