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
                    for: AccountModel.self,
                        BalanceModel.self,
                        BlockchainModel.self,
                        KeyStoreModel.self,
                        TokenModel.self,
                        SavedAddressModel.self,
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

        register(BlockchainClientProvider.self) {
            BlockchainClientProvider()
        }

        register(DatabaseService.self) {
            DatabaseService(modelContainer: DI.injectOrFail(ModelContainer.self))
        }

        register(HardwareService.self) {
            HardwareService()
        }

        register(KeyStoreService.self) {
            KeyStoreService()
        }

        register(TransactionService.self) {
            TransactionService()
        }

        return self
    }
}
