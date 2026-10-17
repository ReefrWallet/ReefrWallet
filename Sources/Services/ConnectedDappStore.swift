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

    func savePermissions(origin: String, permissions: Set<DappSession.Permission>) async {
        let grants = permissions
            .map { ConnectedDappGrant(accountAddress: $0.accountAddress, namespace: $0.namespace.rawValue) }
            .sorted { ($0.namespace, $0.accountAddress) < ($1.namespace, $1.accountAddress) }

        if let model = browserDapp(origin: origin) {
            model.grants = grants
            model.connectedAt = .now
            save()
            return
        }

        guard !grants.isEmpty, let url = Self.url(forOrigin: origin) else {
            return
        }

        context.insert(
            ConnectedDappModel(
                kind: .browser,
                name: url.host() ?? origin,
                urlString: url.absoluteString,
                origin: origin,
                iconURLString: Self.faviconURL(for: url)?.absoluteString,
                grants: grants
            )
        )

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
