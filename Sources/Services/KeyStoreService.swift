//
//  KeyStoreService.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 06.01.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation
import SwiftData
import WalletKit

// MARK: - KeyStoreService

final class KeyStoreService {
    private lazy var databaseService = DI.injectOrFail(DatabaseService.self)
    private lazy var deviceManager = HardwareDeviceManager()

    @MainActor
    func addLocalKey(_ mnemonic: Mnemonic) async throws {
        let rawKey = mnemonic.toSeed().exportRaw()
        let keyStore = KeyStore(.local, name: "Key Store", rawKey: rawKey)
        try await databaseService.saveKeyStore(keyStore)
    }

    @MainActor
    func connectTrezor() async throws {
        let devices = try await deviceManager.scan(vendors: [.trezor], transports: [.usb])
        printInfo("Found \(devices.count) devices")

        guard let device = devices.first else {
            throw Error.notFound
        }

        let keyStore = KeyStore(device)
        try await databaseService.saveKeyStore(keyStore)
    }

    func generateSeedPhrase() -> String {
        Mnemonic.generate(wordCount: .words12).phrase
    }
}
