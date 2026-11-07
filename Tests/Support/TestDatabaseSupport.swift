import Foundation
import SwiftData
import WalletKit
@testable import ReefrWallet

// MARK: - Database

func makeDatabaseService() throws -> DatabaseService {
    let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(
        for: AccountModel.self,
            ApprovalModel.self,
            ApprovalScanModel.self,
            BalanceModel.self,
            BlockchainModel.self,
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

    return DatabaseService(modelContainer: container)
}

func makeWatchOnlyKeyStore(
    databaseService: DatabaseService,
    name: String = "Anvil Watch-Only Test Key Store"
) async throws -> KeyStore {
    let keyStoreId = try await databaseService.insertKeyStore(KeyStore(
        deviceId: nil,
        kind: .watchOnly,
        name: name,
        transport: nil,
        vendor: nil
    ))

    return KeyStore(
        deviceId: nil,
        id: keyStoreId,
        kind: .watchOnly,
        name: name,
        transport: nil,
        vendor: nil
    )
}

/// A `.local` keystore backed by a freshly-generated mnemonic — able to
/// actually sign, unlike the watch-only keystores elsewhere in this file.
func makeLocalKeyStore(
    databaseService: DatabaseService,
    name: String = "Anvil Local Test Key Store"
) async throws -> KeyStore {
    let mnemonic = Mnemonic.generate(wordCount: .`12`)
    let keyStoreId = try await databaseService.insertKeyStore(KeyStore(
        deviceId: nil,
        kind: .local,
        name: name,
        mnemonicWordlist: mnemonic.wordlist,
        sealedEntropy: mnemonic.entropy,
        transport: nil,
        vendor: nil
    ))

    return KeyStore(
        deviceId: nil,
        id: keyStoreId,
        kind: .local,
        name: name,
        mnemonicWordlist: mnemonic.wordlist,
        sealedEntropy: mnemonic.entropy,
        transport: nil,
        vendor: nil
    )
}
