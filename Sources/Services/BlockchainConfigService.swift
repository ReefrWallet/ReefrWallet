//
//  BlockchainConfigService.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 16.02.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation
import WalletKit

final class BlockchainConfigService {
    private(set) var configuredBlockchains: [BlockchainConfig]

    init() {
        configuredBlockchains = []

        do {
            try readConfig()
        } catch {
            printError(error)
            assertionFailure()
        }
    }
}

private extension BlockchainConfigService {
    func readConfig() throws {
        guard let fileURL = Bundle.main.url(forResource: "Blockchains", withExtension: "json") else {
            preconditionFailure("Missing blockchains configuration file")
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let data = try Data(contentsOf: fileURL)
        configuredBlockchains = try decoder.decode([BlockchainConfig].self, from: data)
    }
}
