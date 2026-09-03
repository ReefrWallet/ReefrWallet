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
    let databaseService: DatabaseService

    init() {
        self.databaseService = DI.injectOrFail(DatabaseService.self)
        processStartupOptions()
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
    func processStartupOptions() {
        #if DEBUG
        if CommandLine.arguments.contains("--drop-accounts") {
            Task {
                try? await databaseService.deleteAllAccounts()
            }
        }
        #endif
    }
}
