//
//  DappSession.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 25.09.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

/// One connected origin's permission/account state, for one browser
/// window/tab — an actor since ``DappBridge`` (`@MainActor`) and
/// concurrently-dispatched ``DappProvider``s both touch it. Permissions
/// are kept in memory and mirrored to an optional ``DappPermissionPersisting``
/// store, which restores them when the origin is next visited (ADR-035).
actor DappSession {
    /// One namespace/origin/account permission grant.
    struct Permission: Hashable, Sendable {
        let origin: String
        let namespace: DappNamespace
        let accountAddress: String
    }

    private(set) var origin: String
    private(set) var activeAccount: Account?
    private(set) var permissions: Set<Permission> = []

    private var isApproving = false
    private var approvalWaiters: [CheckedContinuation<Void, Never>] = []
    private let persistence: (any DappPermissionPersisting)?

    init(origin: String, persistence: (any DappPermissionPersisting)? = nil) {
        self.origin = origin
        self.persistence = persistence
    }

    /// Loads the persisted grants for the current origin — call once after
    /// creating a session whose initial origin may already be connected.
    func restorePermissions() async {
        guard let persistence else {
            return
        }

        permissions.formUnion(await persistence.loadPermissions(origin: origin))
    }

    /// The namespace `activeAccount`'s blockchain belongs to, or `nil`
    /// when nothing is selected or its chain has no namespace yet.
    var activeNamespace: DappNamespace? {
        activeAccount.flatMap { DappNamespace.namespace(for: $0.blockchain) }
    }

    /// The browser's single active account, if it belongs to
    /// `namespace` — `nil` for every other namespace, which is how
    /// switching chain families makes the rest look disconnected
    /// without touching their permission grants.
    func selectedAccount(_ namespace: DappNamespace) -> Account? {
        namespace == activeNamespace ? activeAccount : nil
    }

    /// Whether the origin is permitted to see `namespace`'s currently
    /// selected account.
    func isPermitted(_ namespace: DappNamespace) -> Bool {
        guard let account = selectedAccount(namespace) else {
            return false
        }

        return permissions.contains(Permission(origin: origin, namespace: namespace, accountAddress: account.address))
    }

    /// Grants `namespace` permission for the `origin`/`account` the user
    /// approved — called after a `.connect` approval. Commits only if the
    /// session still has that origin and selected account; returns `false`
    /// (granting nothing) when either changed while the prompt was open,
    /// so an approval can't land on a different site or account.
    func grantPermission(_ namespace: DappNamespace, origin approvedOrigin: String, account: Account) async -> Bool {
        guard approvedOrigin == origin, selectedAccount(namespace) == account else {
            return false
        }

        permissions.insert(Permission(origin: origin, namespace: namespace, accountAddress: account.address))
        await persist()
        return true
    }

    /// Switches the browser's one active account to one the *user* picked —
    /// the unified key-store/account selector, or `wallet_switchEthereumChain`
    /// moving to the same key on a different EVM network. Carries a
    /// permission forward whenever the target namespace already holds
    /// any outstanding grant at this origin: the user, not the dapp,
    /// chose this switch, so a namespace already trusted here doesn't
    /// need a fresh approval, even after a detour through another
    /// namespace in between.
    ///
    /// An account the app picked on the user's behalf goes through
    /// ``replaceActiveAccount(_:)`` instead, which grants nothing.
    func setActiveAccount(_ account: Account) async {
        let newNamespace = DappNamespace.namespace(for: account.blockchain)

        let namespaceAlreadyPermitted = newNamespace.map { namespace in
            permissions.contains { $0.origin == origin && $0.namespace == namespace }
        } ?? false

        activeAccount = account

        if namespaceAlreadyPermitted, let newNamespace {
            permissions.insert(Permission(origin: origin, namespace: newNamespace, accountAddress: account.address))
            await persist()
        }
    }

    /// Switches the active account *without* carrying any permission forward —
    /// for a replacement the app made on its own, not one the user chose: the
    /// selector's fallback pick after the selected account was deleted, or its
    /// very first default pick.
    ///
    /// Deliberately not ``setActiveAccount(_:)``: that method's carry-forward
    /// is justified by the user having chosen the switch, which an automatic
    /// pick can't claim. Without this split, deleting a connected account
    /// would hand the already-connected origin whichever account the fallback
    /// landed on, with no approval prompt. A grant left behind for the account
    /// that went away is inert — ``isPermitted(_:)`` only ever matches the
    /// currently selected account's address.
    func replaceActiveAccount(_ account: Account) {
        activeAccount = account
    }

    /// Clears the active account — used when the selector's current
    /// selection no longer exists (e.g. its account was deleted) and no
    /// valid fallback remains. Every namespace reports disconnected
    /// afterward; existing permission grants are untouched.
    func clearActiveAccount() {
        activeAccount = nil
    }

    /// Revokes every permission grant for `namespace` at the current
    /// origin — used by Wallet Standard's explicit `standard:disconnect`
    /// feature (EIP-1193 has no equivalent wallet-side disconnect
    /// concept, so nothing calls this for `.ethereum` today).
    ///
    /// Namespace-wide, not just the currently-active account:
    /// `setActiveAccount` carries a permission forward across an account
    /// switch, so revoking only the currently-active account's grant
    /// would leave an earlier account's carried-forward grant intact,
    /// silently reconnecting it if the selector switches back.
    func revokePermission(_ namespace: DappNamespace) async {
        permissions = permissions.filter { !($0.origin == origin && $0.namespace == namespace) }
        await persist()
    }

    /// Updates the origin, clearing every permission grant for the
    /// previous origin and restoring any persisted for the new one. The
    /// active account carries over unchanged: it's controlled by the
    /// browser's selector, not by which page is loaded, so a dapp on a
    /// freshly navigated origin sees an account to request rather than
    /// looking disconnected until the person reselects one.
    /// Returns `true` when the origin actually changed (so the caller
    /// knows whether to notify every provider via `sessionDidChange`).
    @discardableResult
    func updateOrigin(_ newOrigin: String) async -> Bool {
        guard newOrigin != origin else {
            return false
        }

        origin = newOrigin
        permissions = []

        if let persistence {
            let restored = await persistence.loadPermissions(origin: newOrigin)
            if origin == newOrigin {
                permissions = restored
            }
        }

        return true
    }

    /// A `Sendable` snapshot of this session's current state, for
    /// ``DappProvider/sessionDidChange(_:)``.
    func snapshot() -> DappSessionSnapshot {
        var accounts: [DappNamespace: Account] = [:]
        if let activeNamespace, let activeAccount {
            accounts[activeNamespace] = activeAccount
        }

        return DappSessionSnapshot(
            origin: origin,
            accounts: accounts,
            permittedNamespaces: Set(DappNamespace.allCases.filter(isPermitted)),
            activeAccount: activeAccount,
            activeNamespace: activeNamespace
        )
    }

    /// Runs `body` with every other caller's approval requests queued
    /// behind it — the serial approval queue shared across namespaces,
    /// so two dapp requests never present overlapping approval prompts.
    func withExclusiveApproval<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        Logger.verbose("Dapp approval slot: waiting, busy: \(isApproving), queued: \(approvalWaiters.count)")
        await acquireApprovalSlot()
        Logger.verbose("Dapp approval slot: acquired")
        defer {
            releaseApprovalSlot()
            Logger.verbose("Dapp approval slot: released")
        }

        return try await body()
    }

    private func persist() async {
        guard let persistence else {
            return
        }

        await persistence.savePermissions(origin: origin, permissions: permissions.filter { $0.origin == origin })
    }

    private func acquireApprovalSlot() async {
        if !isApproving {
            isApproving = true
            return
        }

        await withCheckedContinuation { continuation in
            approvalWaiters.append(continuation)
        }
    }

    private func releaseApprovalSlot() {
        guard !approvalWaiters.isEmpty else {
            isApproving = false
            return
        }

        approvalWaiters.removeFirst().resume()
    }
}

/// A `Sendable` snapshot of a ``DappSession``'s state, for
/// ``DappProvider/sessionDidChange(_:)`` to compute the events it should
/// emit without holding a reference to the actor itself.
struct DappSessionSnapshot: Equatable, Sendable {
    let origin: String
    let accounts: [DappNamespace: Account]
    let permittedNamespaces: Set<DappNamespace>
    let activeAccount: Account?
    let activeNamespace: DappNamespace?
}

/// A durable store for a ``DappSession``'s permission grants, keyed by
/// origin.
protocol DappPermissionPersisting: Sendable {
    func loadPermissions(origin: String) async -> Set<DappSession.Permission>
    func savePermissions(origin: String, permissions: Set<DappSession.Permission>) async
}
