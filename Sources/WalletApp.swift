//
//  WalletApp.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 13.12.25.
//  Copyright © 2025 Reefr Wallet. All rights reserved.
//

import SwiftData
import SwiftUI

@main struct WalletApp: App {
    var databaseService: DatabaseService!

    init() {
        processPreStartupOptions()
        databaseService = DI.injectOrFail(DatabaseService.self)
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

private extension WalletApp {
    func processPostStartupOptions() {
        #if DEBUG
        if CommandLine.arguments.contains("--drop-accounts") {
            Task {
                try? await databaseService.deleteAllAccounts()
            }
        }
        #endif
    }

    func processPreStartupOptions() {
        if CommandLine.arguments.contains("--test") {
            printInfo("Using test service injection mode")
            Inject.mode = .test
        }
    }
}
