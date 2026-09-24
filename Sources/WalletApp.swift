//
//  WalletApp.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 13.12.25.
//  Copyright © 2025 Reefr Wallet. All rights reserved.
//

import SwiftData
import SwiftUI
import WalletKit

@main struct WalletApp: App {
    var databaseService: DatabaseService!
    var transactionSyncService: TransactionSyncService!
#if DEBUG
    var accountService: AccountService!
    var keyStoreService: KeyStoreService!
#endif

    init() {
        processPreStartupOptions()
        databaseService = DI.injectOrFail(DatabaseService.self)
        transactionSyncService = DI.injectOrFail(TransactionSyncService.self)
#if DEBUG
        accountService = DI.injectOrFail(AccountService.self)
        keyStoreService = DI.injectOrFail(KeyStoreService.self)
#endif
        let accountService = accountService!
        let keyStoreService = keyStoreService!
        let persistedDatabaseService = databaseService!
        let syncService = transactionSyncService!
        Task {
            await Self.processPostStartupOptions(
                accountService: accountService,
                databaseService: persistedDatabaseService,
                keyStoreService: keyStoreService
            )
            await syncService.startAll()
        }
    }

    var body: some Scene {
        WindowGroup {
            MainView()
        }
        .commandsRemoved()
        .modelContainer(databaseService.modelContainer)

#if os(macOS)
        Settings {
            SettingsView()
        }
#endif
    }
}

#if DEBUG

private extension WalletApp {
    static func processPostStartupOptions(
        accountService: AccountService,
        databaseService: DatabaseService,
        keyStoreService: KeyStoreService
    ) async {
        do {
            if commandLineFlag("--drop-accounts") {
                printInfo("Deleting all accounts.")
                try await databaseService.deleteAllAccounts()
            }

            if commandLineFlag("--drop-transactions") {
                printInfo("Deleting all transactions and sync state.")
                try await databaseService.deleteAllTransactions()
            }

            if commandLineFlag("--drop-tokens") {
                printInfo("Deleting all tokens and balances.")
                try await databaseService.deleteAllTokens()
            } else if commandLineFlag("--drop-balances") {
                printInfo("Deleting all balances.")
                try await databaseService.deleteAllBalances()
            }
        } catch {
            printError(error)
        }

        if let seedPhrase = commandLineValue(after: "--mnemonic") {
            printInfo("Using seed phrase from command-line arguments.")

            do {
                let mnemonic = try Mnemonic.fromPhrase(seedPhrase)

                guard let keyStore = try await keyStoreService.addLocalKey(mnemonic) else {
                    fatalError("Cannot add key store.")
                }

                printInfo("Initialized testing key store.")

                let accountConfigurations: [(WKBlockchain, URL?, BitcoinBackendKind?)] = [
                    (.bitcoin(.regtest), commandLineURL(after: "--bitcoin-rpc-url"), .esplora),
                    (.evm(.ethereum(.sepolia)), commandLineURL(after: "--evm-rpc-url"), nil),
                    (.solana(.devnet), commandLineURL(after: "--solana-rpc-url"), nil),
                    (.sui(.testnet), commandLineURL(after: "--sui-rpc-url"), nil)
                ]

                for (blockchain, rpcURL, bitcoinBackend) in accountConfigurations {
                    for _ in 0 ..< 2 {
                        try await accountService.makeAccount(
                            blockchain,
                            keyStore: keyStore,
                            rpcURLOverride: rpcURL,
                            bitcoinBackend: bitcoinBackend
                        )
                    }
                }

                printInfo("Initialized local testnet accounts.")
            } catch {
                printError(error)
            }
        }
    }

    func processPreStartupOptions() {
        if Self.commandLineFlag("--test") || isRunningXCTest {
            printDebug("Using test service injection mode.")
            Inject.mode = .test
        }
    }

    /// Xcode sets this environment variable on any process it launches to host XCTest,
    /// including plain unit tests that don't receive the app's own launch arguments.
    /// Detecting it here keeps every test run off the real on-disk store automatically.
    var isRunningXCTest: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    static func commandLineFlag(_ parameter: String) -> Bool {
        CommandLine.arguments.contains(parameter)
    }

    static func commandLineURL(after argument: String) -> URL? {
        guard let value = commandLineValue(after: argument) else {
            return nil
        }

        return URL(string: value)
    }

    static func commandLineValue(after argument: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: argument),
              CommandLine.arguments.count > index + 1 else {
            return nil
        }

        return CommandLine.arguments[index + 1]
    }
}

#endif
