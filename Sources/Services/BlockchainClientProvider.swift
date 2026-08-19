//
//  BlockchainClientProvider.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 25.02.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation
import SwiftData
import WalletKit

private struct Target: Hashable {
    let url: URL
    let blockchain: Blockchain
}

final class BlockchainClientProvider {
    private var clients: [Target: any BlockchainClientProtocol] = [:]

    func getClient(_ account: Account) throws -> any BlockchainClientProtocol {
        try getClient(account.blockchainConfig.blockchain, account.blockchainConfig.endpointURL)
    }
}

private extension BlockchainClientProvider {
    func getClient(_ blockchain: Blockchain, _ endpoint: URL) throws -> any BlockchainClientProtocol {
        let target = Target(url: endpoint, blockchain: blockchain)

        if let client = clients[target] {
            return client
        }

        let client = try makeClient(blockchain: blockchain, endpoint: endpoint)
        clients[target] = client
        return client
    }

    func makeClient(blockchain: Blockchain, endpoint: URL) throws -> any BlockchainClientProtocol {
        switch blockchain {
        case let .ethereum(chainId):
            return EthereumRPCClient(endpoint: endpoint, chainId: chainId)
        case .sui:
            guard let host = endpoint.host else {
                throw WalletKitError.invalidAddress(reason: "Invalid Sui endpoint: \(endpoint)")
            }

            let port = endpoint.port ?? 443
            let useTLS = endpoint.scheme == "https"

            return SuiGRPCClient(host: host, port: port, useTLS: useTLS)
        default:
            throw WalletKitError.internalError(message: "Not implemented yet")
        }
    }
}
