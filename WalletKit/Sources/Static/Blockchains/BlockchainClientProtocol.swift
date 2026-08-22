//
//  BlockchainClientProtocol.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 18.02.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

@_exported import BigInt

public enum BlockchainClientFeature {
    case allBalances
}

public protocol BlockchainClientProtocol {
    func getAllBalances(_ owner: String) async throws -> [String: BigUInt]
    func getBalance(_ owner: String, token: String) async throws -> BigUInt
    func getNativeBalance(_ owner: String) async throws -> BigUInt
    func getTokenInfo(_ token: String) async throws -> TokenInfo
    func isActiveAccount(_ owner: String) async throws -> Bool
    func isSupported(_ feature: BlockchainClientFeature) -> Bool
}
