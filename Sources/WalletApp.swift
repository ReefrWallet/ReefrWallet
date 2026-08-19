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
    let databaseService: DatabaseService = DI.injectOrFail(DatabaseService.self)

    var body: some Scene {
        WindowGroup {
            MainView()
        }
        .commandsRemoved()
        .modelContainer(databaseService.modelContainer)

        Settings {
            SettingsView()
        }
    }
}
