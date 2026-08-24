//
//  SuiGRPCClient+BlockchainClientProtocol.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 20/08/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

extension SuiGRPCClient: BlockchainClientProtocol {
    public func getAllBalances(_ owner: String) async throws -> [String: BigUInt] {
        let owner = try SuiAddress(string: owner)
        let resposne = try await listAllBalances(of: owner)

        var balances: [String: BigUInt] = [:]
        for balance in resposne {
            balances[balance.coinType] = BigUInt(balance.balance)
        }
        return balances
    }

    public func getBalance(_ owner: String, token: String) async throws -> BigUInt {
        let owner = try SuiAddress(string: owner)
        return BigUInt(try await coinBalance(of: owner, coinType: token))
    }

    public func getNativeBalance(_ owner: String) async throws -> BigUInt {
        let owner = try SuiAddress(string: owner)
        return BigUInt(try await nativeBalance(of: owner))
    }

    public func getTokenInfo(_ token: String?) async throws -> TokenInfo {
        guard let token else {
            return .sui
        }

        return try await coinInfo(coinType: token)
    }

    public func getTokenPrice(_ token: String?) async throws -> Decimal {
        throw WalletKitError.internalError(message: "Not Implemented")
    }

    public func isActiveAccount(_ owner: String) async throws -> Bool {
        let owner = try SuiAddress(string: owner)
        let ownedObjects = try await getOwnedObjects(owner)
        return ownedObjects.isEmpty == false
    }

    public func isSupported(_ feature: BlockchainClientFeature) -> Bool {
        switch feature {
        case .allBalances: true
        }
    }
}
