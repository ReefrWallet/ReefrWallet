//
//  ServiceContainer.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 22.02.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation
import SwiftData

extension ServiceContainer {
    func registerModelContainer(useInMemoryStore: Bool = false) -> Self {
        register(ModelContainer.self) {
            let modelURL = URL.applicationSupportDirectory
                .appending(path: "xyz.reefr.wallet/keystore.sqlite")

            let configuration = if useInMemoryStore {
                ModelConfiguration(isStoredInMemoryOnly: useInMemoryStore)
            } else {
                ModelConfiguration(url: modelURL)
            }

            do {
                return try ModelContainer(
                    for: Account.self, Balance.self, BlockchainConfig.self, KeyStore.self, Token.self,
                    configurations: configuration
                )
            } catch {
                preconditionFailure("Can't create model container: \(error.localizedDescription)")
            }
        }

        return self
    }

    func registerCore() -> Self {
        register(AccountService.self) {
            AccountService()
        }

        register(BalancesService.self) {
            BalancesService()
        }

        register(BlockchainConfigService.self) {
            BlockchainConfigService()
        }

        register(BlockchainClientProvider.self) {
            BlockchainClientProvider()
        }

        register(DatabaseService.self) {
            DatabaseService(modelContainer: DI.injectOrFail(ModelContainer.self))
        }

        register(KeyStoreService.self) {
            KeyStoreService()
        }

        return self
    }
}
