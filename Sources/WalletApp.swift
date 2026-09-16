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
#if DEBUG
    var accountService: AccountService!
    var keyStoreService: KeyStoreService!
#endif

    init() {
        processPreStartupOptions()
        databaseService = DI.injectOrFail(DatabaseService.self)
#if DEBUG
        accountService = DI.injectOrFail(AccountService.self)
        keyStoreService = DI.injectOrFail(KeyStoreService.self)
#endif
        processPostStartupOptions()
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
    func processPostStartupOptions() {
        Task {
            do {
                if CommandLine.arguments.contains("--drop-accounts") {
                    try await databaseService.deleteAllAccounts()
                } else if CommandLine.arguments.contains("--drop-tokens") {
                    try await databaseService.deleteAllTokens()
                } else if CommandLine.arguments.contains("--drop-balances") {
                    try await databaseService.deleteAllBalances()
                }
            } catch {
                printError(error)
            }

            if let index = CommandLine.arguments.firstIndex(of: "--mnemonic"),
               CommandLine.arguments.count > index + 1 {
                let seedPhrase = CommandLine.arguments[index + 1]
                printDebug("Using seed phrase from command-line arguments.")

                do {
                    let mnemonic = try Mnemonic.fromPhrase(seedPhrase)
                    guard let keyStore = try await keyStoreService.addLocalKey(mnemonic) else {
                        fatalError("Cannot add key store.")
                    }
                    printInfo("Initialized testing key store.")

                    for _ in 1 ... 3 {
                        try await accountService.makeAccount(.evm(.ethereum(.testnet)), keyStore: keyStore)
                    }
                    printInfo("Initialized testing accounts.")
                } catch {
                    printError(error)
                }
            }
        }
    }

    func processPreStartupOptions() {
        if CommandLine.arguments.contains("--test") {
            printDebug("Using test service injection mode.")
            Inject.mode = .test
        }
    }
}

#endif
