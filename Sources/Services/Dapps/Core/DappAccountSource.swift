//
//  DappAccountSource.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 27.10.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

/// Where the bridge finds the accounts a dapp can connect with when the
/// browser has none selected for the chain it asked for.
protocol DappAccountSource: Sendable {
    /// Every account on `namespace`'s chains, with its key store's name.
    func choices(for namespace: DappNamespace) async -> [DappAccountChoice]
}

/// The app's accounts, read from the database.
struct DatabaseDappAccountSource: DappAccountSource {
    func choices(for namespace: DappNamespace) async -> [DappAccountChoice] {
        let databaseService = DI.injectOrFail(DatabaseService.self)
        guard let accounts = try? await databaseService.fetchAllAccounts() else {
            return []
        }

        var names: [String: String] = [:]
        var choices: [DappAccountChoice] = []

        for account in accounts where namespace.matches(account.blockchain) {
            let key = "\(account.keyStoreId)"
            if names[key] == nil {
                names[key] = (try? await databaseService.fetchKeyStore(id: account.keyStoreId))?.name ?? ""
            }

            choices.append(DappAccountChoice(account: account, keyStoreName: names[key] ?? ""))
        }

        return choices.sorted { ($0.keyStoreName, $0.account.name) < ($1.keyStoreName, $1.account.name) }
    }
}
