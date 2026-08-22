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
    private var configuredBlockchains: [BlockchainConfig]

    init() {
        configuredBlockchains = []

        do {
            try readConfig()
        } catch {
            printError(error)
            assertionFailure()
        }
    }

    var allBlockchains: [Blockchain] {
        configuredBlockchains
            .filter { $0.isTestnet == false }
            .map(\.blockchain)
    }

    func allNetworks(for blockchain: Blockchain) -> [Blockchain] {
        configuredBlockchains
            .filter { $0.blockchain == blockchain }
            .map(\.blockchain)
    }

    /// Always returns a stored config or throws error
    func getConfig(for blockchain: Blockchain) async throws -> BlockchainConfig {
        let databaseService = DI.injectOrFail(DatabaseService.self)

        if let config = try await databaseService.fetchBlockchainConfig(blockchain) {
            return config
        }

        if let config = configuredBlockchains.first(where: { $0.blockchain == blockchain }) {
            try await databaseService.insertBlockchainConfig(config)
        } else {
            throw Error.notFound
        }

        guard let config = try await databaseService.fetchBlockchainConfig(blockchain) else {
            throw Error.internalError
        }

        return config
    }

    func getDisplayName(for blockchain: Blockchain) -> String? {
        if let config = configuredBlockchains.first(where: { $0.blockchain == blockchain }) {
            config.displayName
        } else {
            nil
        }
    }

    func getNetworkName(for blockchain: Blockchain) -> String? {
        if let config = configuredBlockchains.first(where: { $0.blockchain == blockchain }) {
            config.networkName
        } else {
            nil
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
