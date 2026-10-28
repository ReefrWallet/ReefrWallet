//
//  ConnectedDapp.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 17.10.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation
import SwiftData

enum ConnectedDappKind: String, Codable, Sendable {
    case browser
    case walletConnect
}

/// One namespace/account pair a dapp may see.
struct ConnectedDappGrant: Codable, Hashable, Sendable {
    let accountAddress: String
    let namespace: String
}

/// An entry in the sidebar's "Connected dApps" section: a browser origin
/// with its persisted permission grants, or the single "WalletConnect"
/// hub whose detail pane lists the live sessions (ADR-035).
@Model
final class ConnectedDappModel {
    var connectedAt: Date
    var iconURLString: String?
    var kindRaw: String
    var name: String
    var origin: String
    var serializedGrants: String
    /// Namespaces the page has asked to connect on, as JSON `[String]`: the
    /// chains offered when choosing an account for this dapp.
    var serializedNamespaces: String = "[]"
    /// The account the browser selects when this dapp opens: the one last chosen for it.
    var selectedAccountAddress: String?
    var urlString: String

    init(
        kind: ConnectedDappKind,
        name: String,
        urlString: String,
        origin: String,
        iconURLString: String? = nil,
        grants: [ConnectedDappGrant] = [],
        namespaces: [String] = []
    ) {
        connectedAt = .now
        self.iconURLString = iconURLString
        kindRaw = kind.rawValue
        self.name = name
        self.origin = origin
        serializedGrants = (try? grants.asJSONString()) ?? "[]"
        serializedNamespaces = (try? Array(Set(namespaces)).sorted().asJSONString()) ?? "[]"
        self.urlString = urlString
    }

    var grants: [ConnectedDappGrant] {
        get {
            (try? serializedGrants.decoded()) ?? []
        }

        set {
            serializedGrants = (try? newValue.asJSONString()) ?? "[]"
        }
    }

    /// The chains this dapp asked to connect on, sorted.
    var requestedNamespaces: [String] {
        get {
            (try? serializedNamespaces.decoded()) ?? []
        }

        set {
            serializedNamespaces = (try? Array(Set(newValue)).sorted().asJSONString()) ?? "[]"
        }
    }

    var host: String {
        URL(string: urlString)?.host() ?? urlString
    }

    var iconURL: URL? {
        iconURLString.flatMap { URL(string: $0) }
    }

    var kind: ConnectedDappKind {
        ConnectedDappKind(rawValue: kindRaw) ?? .browser
    }
}
