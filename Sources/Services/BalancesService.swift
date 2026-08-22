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
    private lazy var blockchainConfigService = DI.injectOrFail(BlockchainConfigService.self)
    private lazy var databaseService = DI.injectOrFail(DatabaseService.self)
    // private lazy var priceService = DI.injectOrFail(PriceService.self)

    /// Scan for active accounts and add if necessary
    @MainActor
    func scanAccounts(blockchain: Blockchain, keyStore: KeyStore) async throws {
        guard !keyStore.isWatchOnly else {
            throw Error.invalidData
        }

        let blockchainConfig = try await blockchainConfigService.getConfig(for: blockchain)
        let storedKeyStore = try await databaseService.fetchKeyStore(id: keyStore.id)

        repeat {
            let accountIndex = keyStore.nextAccountIndex(blockchainConfig.blockchain)
            let name = "\(blockchainConfig.displayName) #\(accountIndex + 1)"

            let newAccount = Account(
                accountIndex: accountIndex,
                address: "",
                blockchainConfig: blockchainConfig,
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
        let client =  try clientProvider.getClient(account)

        if client.isSupported(.allBalances) {
            try await updateAllBalances(account)
        } else {
            try await updateTokenBalances(account)
        }

        try await databaseService.saveAccount(account)
    }
}

private extension BalancesService {
    func updateAllBalances(_ account: Account) async throws {
        let client = try clientProvider.getClient(account)

        for (tokenAddress, amount) in try await client.getAllBalances(account.address) {
            let token = account.blockchainConfig.tokens.first {
                $0.address == tokenAddress
            }

            if let token {
                account.setBalance(of: token, amount: amount)
            } else {
                // FIXME: get coin data
                let token = Token(
                    address: tokenAddress,
                    blockchain: account.blockchainConfig,
                    decimalsCount: 8,
                    isNativeToken: false,
                    name: "New token",
                    symbol: "NEW"
                )

                account.setBalance(of: token, amount: amount)
            }
        }

        try await databaseService.saveAccount(account)
    }

    func updateTokenBalances(_ account: Account) async throws {
        let client = try clientProvider.getClient(account)

        for token in account.blockchainConfig.tokens {
            let amount = if token.isNativeToken {
                 try await client.getNativeBalance(account.address)
            } else if let tokenAddress = token.address {
                try await client.getBalance(account.address, token: tokenAddress)
            } else {
                throw Error.invalidData
            }

            account.setBalance(of: token, amount: amount)
        }

        try await databaseService.saveAccount(account)
    }
}
