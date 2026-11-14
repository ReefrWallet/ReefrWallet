//
//  CustomTokenService.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 14.11.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import WalletKit

/// Adds a token by contract address. Balance refreshes only read tokens already in the database.
struct CustomTokenService {
    let databaseService: DatabaseService

    /// Reads the token's info, saves it for the whole blockchain as not hidden and queues `account`'s
    /// balance for it. An already stored token is not read again.
    @discardableResult
    func addToken(contractAddress: String, account: Account) async throws -> Token {
        let blockchain = account.blockchain
        let address = try Self.normalizedAddress(contractAddress, blockchain: blockchain)

        let token: Token
        if let existing = try await storedToken(address: address, blockchain: blockchain) {
            token = existing
        } else {
            let client = try DI.injectOrFail(BlockchainClientProvider.self).makeClient(
                blockchain: blockchain,
                rpcURL: account.rpcURLOverride
            )

            let tokenInfo = try await client.getTokenInfo(address)

            guard !tokenInfo.isNative else {
                throw ReefrError.invalidAddress
            }

            token = Token(address: address, blockchain: blockchain, tokenInfo: tokenInfo)
            try await databaseService.insertToken(token, blockchain: blockchain)
        }

        // Unidentified tokens would otherwise land in hidden balances.
        try await databaseService.setTokenHidden(token, isHidden: false)

        await DI.injectOrFail(BalancesService.self).enqueueBalanceUpdate(
            account: account,
            tokenAddress: token.address,
            blockchain: blockchain
        )

        return token
    }

    /// Validates `string` as a contract address: checksummed on EVM, Base58Check on Tron.
    static func normalizedAddress(_ string: String, blockchain: Blockchain) throws -> String {
        let string = string.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            switch blockchain {
            case .evm:
                return try EthereumAddress(string: string).string
            case .tron:
                return try TronAddress(string: string).string
            default:
                throw ReefrError.notSupported
            }
        } catch is WalletKitError {
            throw ReefrError.invalidAddress
        }
    }

    /// EVM rows may hold the lowercase spelling of the same contract.
    private func storedToken(address: String, blockchain: Blockchain) async throws -> Token? {
        if let token = try await databaseService.fetchToken(tokenAddress: address, blockchain: blockchain) {
            return token
        }

        guard case .evm = blockchain else {
            return nil
        }

        return try await databaseService.fetchToken(tokenAddress: address.lowercased(), blockchain: blockchain)
    }
}

extension Blockchain {
    /// Chains whose tokens can be added by contract address: EVM and Tron.
    var supportsCustomTokens: Bool {
        switch self {
        case .evm, .tron:
            true
        default:
            false
        }
    }
}
