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
            let modelURL = URL.applicationSupportDirectory.appending(path: "xyz.reefr.wallet/keystore.sqlite")

            let configuration: ModelConfiguration

            if let storeURL = Inject.storeURLOverride {
                printDebug("Using SQLite store override at \(storeURL.path)")
                configuration = ModelConfiguration(url: storeURL)
            } else if useInMemoryStore {
                printDebug("Using in-memory SQLite store")
                configuration = ModelConfiguration(isStoredInMemoryOnly: useInMemoryStore)
            } else {
                printDebug("Using SQLite store at \(modelURL.path)")
                configuration = ModelConfiguration(url: modelURL)
            }

            do {
                return try ModelContainer(
                    for: AccountModel.self,
                        BalanceModel.self,
                        BlockchainModel.self,
                        KeyStoreModel.self,
                        TokenModel.self,
                        SavedAddressModel.self,
                        WalletTransactionModel.self,
                        WalletTransactionEffectModel.self,
                        WalletTransactionSyncStateModel.self,
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

        register(DappSigningService.self) {
            DappSigningService()
        }

        register(DatabaseService.self) {
            let databaseService = DatabaseService(modelContainer: DI.injectOrFail(ModelContainer.self))

            if case .preview = Inject.mode {
                Task {
                    printDebug("Generating mock preview data...")

                    do {
                        try await databaseService.mockPreviewData()
                    } catch {
                        printError(error)
                    }
                }
            }

            return databaseService
        }

        register(FeeEstimationService.self) {
            FeeEstimationService()
        }

        register(HardwareService.self) {
            HardwareService()
        }

        register(KeyStoreService.self) {
            KeyStoreService()
        }

        register(TokenPriceService.self) {
            TokenPriceService()
        }

        register(TransactionService.self) {
            TransactionService()
        }

        register(TransactionSyncService.self) {
            TransactionSyncService()
        }

        return self
    }
}
