//
//  SuiGRPCClient+BlockchainClientProtocol.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 20/08/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

extension SuiGRPCClient: BlockchainClientProtocol {
    public func getBalance(_ owner: String, token: String) async throws -> BigUInt {
        let owner = try SuiAddress(string: owner)
        return BigUInt(try await coinBalance(of: owner, coinType: token))
    }

    public func getNativeBalance(_ owner: String) async throws -> BigUInt {
        let owner = try SuiAddress(string: owner)
        return BigUInt(try await nativeBalance(of: owner))
    }

    public func isActiveAccount(_ owner: String) async throws -> Bool {
        let owner = try SuiAddress(string: owner)
        let ownedObjects = try await getOwnedObjects(owner)
        return ownedObjects.isEmpty == false
    }
}
