//
//  ServiceContainer.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 22.02.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation
import SwiftData
import Synchronization

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
                        ApprovalModel.self,
                        ApprovalScanModel.self,
                        BalanceModel.self,
                        BlockchainModel.self,
                        ConnectedDappModel.self,
                        KeyStoreModel.self,
                        ReceiveAddressModel.self,
                        TokenModel.self,
                        TokenSourceStatusModel.self,
                        SavedAddressModel.self,
                        StakingModel.self,
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

    // swiftlint:disable:next function_body_length
    func registerCore() -> Self {
        register(AccountService.self) {
            AccountService()
        }

        register(ApprovalService.self) {
            ApprovalService()
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
            let container = DI.injectOrFail(ModelContainer.self)
            let databaseService = Self.makeDatabaseService(container: container)

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

        register(CardanoStakingPositionLoader.self) {
            CardanoStakingPositionLoader()
        }

        register(CardanoStakingService.self) {
            CardanoStakingService()
        }

        register(SolanaStakingPositionLoader.self) {
            SolanaStakingPositionLoader()
        }

        register(SolanaStakingService.self) {
            SolanaStakingService()
        }

        register(StakingStateService.self) {
            StakingStateService()
        }

        register(SuiStakingPositionLoader.self) {
            SuiStakingPositionLoader()
        }

        register(SuiStakingService.self) {
            SuiStakingService()
        }

        register(TokenIdentityScheduler.self) {
            TokenIdentityScheduler()
        }

        register(TokenIdentityService.self) {
            TokenIdentityService()
        }

        register(TokenPriceScheduler.self) {
            TokenPriceScheduler()
        }

        register(TokenPriceService.self) {
            TokenPriceService()
        }

        register(TransactionService.self) {
            TransactionService()
        }

        register(TronStakingPositionLoader.self) {
            TronStakingPositionLoader()
        }

        register(TronStakingService.self) {
            TronStakingService()
        }

        register(TransactionSyncService.self) {
            TransactionSyncService()
        }

        return self
    }

    private static func makeDatabaseService(container: ModelContainer) -> DatabaseService {
        // A context created on the main thread binds its executor there.
        // Keep one writer, but create its context off the main thread.
        let service = Mutex<DatabaseService?>(nil)
        let ready = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            service.withLock { $0 = DatabaseService(modelContainer: container) }
            ready.signal()
        }

        ready.wait()
        return service.withLock { $0! }
    }

    func registerKeyVault() -> Self {
        register(KeyVault.self) {
            switch Inject.mode {
            case .standard: KeychainKeyVault()
            case .preview, .test: PassthroughKeyVault()
            }
        }

        return self
    }
}

extension ServiceContainer {
    func registerDapps() -> Self {
        register(ConnectedDappStore.self) {
            MainActor.assumeIsolated {
                ConnectedDappStore(modelContainer: DI.injectOrFail(ModelContainer.self))
            }
        }

        register(WalletConnectService.self) {
            MainActor.assumeIsolated {
                WalletConnectService()
            }
        }

        return self
    }
}
