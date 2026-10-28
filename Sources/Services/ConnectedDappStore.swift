//
//  ConnectedDappStore.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 17.10.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation
import SwiftData

/// Reads and writes ``ConnectedDappModel``s on the main context, and is
/// the ``DappSession`` permission store for browser tabs (ADR-035).
@MainActor
final class ConnectedDappStore: DappPermissionPersisting {
    private let modelContainer: ModelContainer
    /// Namespaces requested before the origin has an entry (nothing approved yet).
    private var pendingNamespaces: [String: Set<String>] = [:]
    private var pendingSelections: [String: String] = [:]

    private var context: ModelContext {
        modelContainer.mainContext
    }

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    /// Adds a browser entry for `url` without any grants — the sidebar's "+".
    @discardableResult
    func addBrowserDapp(url: URL, name: String? = nil) -> ConnectedDappModel {
        let origin = Self.origin(for: url)

        if let existing = browserDapp(origin: origin) {
            return existing
        }

        let model = ConnectedDappModel(
            kind: .browser,
            name: name ?? url.host() ?? url.absoluteString,
            urlString: url.absoluteString,
            origin: origin,
            iconURLString: Self.faviconURL(for: url)?.absoluteString
        )

        context.insert(model)
        save()
        return model
    }

    func remove(_ model: ConnectedDappModel) {
        context.delete(model)
        save()
    }

    /// Points `namespace`'s grant at `accountAddress` (or removes it when `nil`),
    /// from the dapp's details pane.
    func setGrant(_ dapp: ConnectedDappModel, namespace: String, accountAddress: String?) {
        var grants = dapp.grants.filter { $0.namespace != namespace }
        if let accountAddress {
            grants.append(ConnectedDappGrant(accountAddress: accountAddress, namespace: namespace))
        }

        dapp.grants = grants.sorted { ($0.namespace, $0.accountAddress) < ($1.namespace, $1.accountAddress) }
        save()
    }

    /// Connects the dapp with `accountAddress` on that account's chain and makes it
    /// the account the browser opens with, or disconnects the dapp when `nil`.
    func connect(_ dapp: ConnectedDappModel, accountAddress: String?, namespace: String?) {
        guard let accountAddress, let namespace else {
            dapp.grants = []
            dapp.selectedAccountAddress = nil
            save()
            return
        }

        setGrant(dapp, namespace: namespace, accountAddress: accountAddress)
        dapp.selectedAccountAddress = accountAddress
        save()
    }

    /// Disconnects the dapp on `namespace` only, forgetting its remembered account
    /// if that was the one on this chain.
    func disconnect(_ dapp: ConnectedDappModel, namespace: String) {
        let removed = dapp.grants.first { $0.namespace == namespace }?.accountAddress
        setGrant(dapp, namespace: namespace, accountAddress: nil)

        if let removed, dapp.selectedAccountAddress == removed {
            dapp.selectedAccountAddress = nil
            save()
        }
    }

    /// Makes `accountAddress` the account the browser opens this dapp with.
    func select(_ dapp: ConnectedDappModel, accountAddress: String) {
        dapp.selectedAccountAddress = accountAddress
        save()
    }

    /// Drops every browser grant for `addresses`.
    func revokeGrants(addresses: Set<String>) {
        let models = (try? context.fetch(FetchDescriptor<ConnectedDappModel>())) ?? []

        for model in models where model.kind == .browser {
            let grants = model.grants
            let kept = grants.filter { !addresses.contains($0.accountAddress) }

            if kept.count != grants.count {
                model.grants = kept
            }
        }

        save()
    }

    /// The single "WalletConnect" sidebar entry, created on first use.
    @discardableResult
    func ensureWalletConnectHub() -> ConnectedDappModel {
        let kindRaw = ConnectedDappKind.walletConnect.rawValue
        let descriptor = FetchDescriptor<ConnectedDappModel>(predicate: #Predicate { $0.kindRaw == kindRaw })

        if let existing = try? context.fetch(descriptor).first {
            return existing
        }

        let hub = ConnectedDappModel(
            kind: .walletConnect, name: "WalletConnect", urlString: "https://walletconnect.network", origin: "walletconnect"
        )

        context.insert(hub)
        save()
        return hub
    }

    // MARK: DappPermissionPersisting

    func loadPermissions(origin: String) async -> Set<DappSession.Permission> {
        guard let model = browserDapp(origin: origin) else {
            return []
        }

        return Set(
            model.grants.compactMap { grant in
                DappNamespace(rawValue: grant.namespace).map {
                    DappSession.Permission(origin: origin, namespace: $0, accountAddress: grant.accountAddress)
                }
            }
        )
    }

    func loadSelectedAccount(origin: String) async -> String? {
        browserDapp(origin: origin)?.selectedAccountAddress ?? pendingSelections[origin]
    }

    func saveSelectedAccount(origin: String, address: String) async {
        guard let model = browserDapp(origin: origin) else {
            pendingSelections[origin] = address
            return
        }

        if model.selectedAccountAddress != address {
            model.selectedAccountAddress = address
            save()
        }
    }

    func noteConnectRequest(origin: String, namespace: DappNamespace) async {
        if let model = browserDapp(origin: origin) {
            if !model.requestedNamespaces.contains(namespace.rawValue) {
                model.requestedNamespaces += [namespace.rawValue]
                save()
            }

            return
        }

        pendingNamespaces[origin, default: []].insert(namespace.rawValue)
    }

    func savePermissions(origin: String, permissions: Set<DappSession.Permission>) async {
        let grants = permissions
            .map { ConnectedDappGrant(accountAddress: $0.accountAddress, namespace: $0.namespace.rawValue) }
            .sorted { ($0.namespace, $0.accountAddress) < ($1.namespace, $1.accountAddress) }

        if let model = browserDapp(origin: origin) {
            model.grants = grants
            model.requestedNamespaces += pendingNamespaces.removeValue(forKey: origin).map(Array.init) ?? []
            model.selectedAccountAddress = model.selectedAccountAddress ?? pendingSelections.removeValue(forKey: origin)
            model.connectedAt = .now
            save()
            return
        }

        guard !grants.isEmpty, let url = Self.url(forOrigin: origin) else {
            return
        }

        let created = ConnectedDappModel(
            kind: .browser,
            name: url.host() ?? origin,
            urlString: url.absoluteString,
            origin: origin,
            iconURLString: Self.faviconURL(for: url)?.absoluteString,
            grants: grants,
            namespaces: Array(pendingNamespaces.removeValue(forKey: origin) ?? [])
        )

        created.selectedAccountAddress = pendingSelections.removeValue(forKey: origin)
        context.insert(created)

        save()
    }

    // MARK: Helpers

    /// Matches ``DappBridge``'s `"\(protocol)://\(host):\(port)"` origin string.
    static func origin(for url: URL) -> String {
        "\(url.scheme ?? "")://\(url.host() ?? ""):\(url.port ?? 0)"
    }

    private static func faviconURL(for url: URL) -> URL? {
        guard let scheme = url.scheme, let host = url.host() else {
            return nil
        }

        return URL(string: "\(scheme)://\(host)/favicon.ico")
    }

    private static func url(forOrigin origin: String) -> URL? {
        guard
            let components = URLComponents(string: origin),
            let scheme = components.scheme,
            let host = components.host
        else {
            return nil
        }

        return URL(string: "\(scheme)://\(host)")
    }

    private func browserDapp(origin: String) -> ConnectedDappModel? {
        let kindRaw = ConnectedDappKind.browser.rawValue
        let descriptor = FetchDescriptor<ConnectedDappModel>(
            predicate: #Predicate { $0.kindRaw == kindRaw && $0.origin == origin }
        )

        return try? context.fetch(descriptor).first
    }

    private func save() {
        do {
            try context.save()
        } catch {
            printError(error)
        }
    }
}
