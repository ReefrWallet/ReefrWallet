//
//  File.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 20/08/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

extension EthereumRPCClient: BlockchainClientProtocol {
    public func getBalance(_ owner: String, token: String) async throws -> BigUInt {
        let owner = try EthereumAddress(string: owner)
        let token = try EthereumAddress(string: token)
        return try await erc20Balance(token: token, owner: owner)
    }

    public func getNativeBalance(_ owner: String) async throws -> BigUInt {
        let owner = try EthereumAddress(string: owner)
        return try await nativeBalance(of: owner)
    }

    public func isActiveAccount(_ owner: String) async throws -> Bool {
        let owner = try EthereumAddress(string: owner)

        let balance = try await nativeBalance(of: owner)
        guard balance == 0 else {
            return false
        }

        let nonce = try await nonce(of: owner)
        guard nonce == 0 else {
            return false
        }

        return true
    }
}
