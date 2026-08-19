//
//  BalancesService.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 17.01.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation
import SwiftData
import SwiftUI
import WalletKit

/// This service fetches account balances from blockchain and saves them in the database

final class BalancesService {
    private lazy var clientProvider = DI.injectOrFail(BlockchainClientProvider.self)
    private lazy var databaseService = DI.injectOrFail(DatabaseService.self)
    // private lazy var priceService = DI.injectOrFail(PriceService.self)

    /// Scan for active accounts and add if necessary
    @MainActor
    func scanAccounts(blockchainConfig: BlockchainConfig, keyStore: KeyStore) async throws {
        guard !keyStore.isWatchOnly else {
            throw Error.invalidData
        }

        let storedBlockchain = try await databaseService.fetchBlockchainConfig(blockchainConfig)
        let storedKeyStore = try await databaseService.fetchKeyStore(id: keyStore.id)

        repeat {
            let accountIndex = keyStore.nextAccountIndex(blockchainConfig.blockchain)
            let name = "\(blockchainConfig.displayName) #\(accountIndex + 1)"

            let newAccount = Account(
                accountIndex: accountIndex,
                address: "",
                blockchainConfig: storedBlockchain,
                keyStore: storedKeyStore,
                name: name
            )

            let client = try clientProvider.getClient(newAccount)

            guard try await client.isActiveAccount(newAccount.address) else {
                return
            }

            storedKeyStore.accounts?.append(newAccount)
        } while true

        try await databaseService.saveKeyStore(storedKeyStore)
    }

    @MainActor
    func updateBalances(_ account: Account) async throws {
        /* let client =  try clientProvider.getClient(account)

        do {
            try await client.updateBalances(account)
        } catch {
            printError(error)
        }

        do {
            try await priceService.updatePrices(account)
        } catch {
            printError(error)
        }

        try await databaseService.saveAccount(account) */
    }
}
