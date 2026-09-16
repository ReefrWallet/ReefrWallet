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
#if DEBUG
    var databaseService: DatabaseService!
    var keyStoreService: KeyStoreService!

    init() {
        processPreStartupOptions()

        databaseService = DI.injectOrFail(DatabaseService.self)
        keyStoreService = DI.injectOrFail(KeyStoreService.self)

        processPostStartupOptions()
    }
#endif

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
        if CommandLine.arguments.contains("--drop-accounts") {
            Task {
                try? await databaseService.deleteAllAccounts()
            }
        }

        if let index = CommandLine.arguments.firstIndex(of: "--mnemonic"), CommandLine.arguments.count > index {
            Task {
                let seedPhrase = CommandLine.arguments[index]
                printDebug("Using seed phrase from command-line arguments.")

                do {
                    let mnemonic = try Mnemonic.fromPhrase(seedPhrase)
                    try await keyStoreService.addLocalKey(mnemonic)
                    printInfo("Initialized testing key store.")
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
