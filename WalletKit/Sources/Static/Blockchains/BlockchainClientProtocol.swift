//
//  BlockchainClientProtocol.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 18.02.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

@_exported import BigInt

public protocol BlockchainClientProtocol {
    func getBalance(_ owner: String, token: String) async throws -> BigUInt
    func getNativeBalance(_ owner: String) async throws -> BigUInt
    func isActiveAccount(_ owner: String) async throws -> Bool
}
