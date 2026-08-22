//
//  Account.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 28.12.25.
//  Copyright © 2025 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation
import SwiftData

// MARK: - Account Model

@Model
final class Account {
    var accountIndex: UInt64?
    var address: String
    var derivationPath: String?
    var name: String

    @Relationship(deleteRule: .cascade, inverse: \Balance.account)
    var balances: [Balance]

    @Relationship
    var blockchainConfig: BlockchainConfig

    @Relationship
    var keyStore: KeyStore?

    init(
        accountIndex: UInt64? = nil,
        address: String,
        blockchainConfig: BlockchainConfig,
        keyStore: KeyStore,
        name: String
    ) {
        guard accountIndex != nil || keyStore.isWatchOnly else {
            preconditionFailure("Missing account index")
        }

        self.accountIndex = accountIndex
        self.address = address
        self.balances = []
        self.blockchainConfig = blockchainConfig
        self.keyStore = keyStore
        self.name = name
    }
}

// MARK: - Comparable

extension Account: Comparable {
    static func < (lhs: Account, rhs: Account) -> Bool {
        (lhs.blockchainConfig.displayName, lhs.blockchainConfig.networkName)
            < (rhs.blockchainConfig.displayName, rhs.blockchainConfig.networkName)
    }
}

// MARK: - Helpers

extension Account {
    var nativeBalance: Balance? {
        balances.first { $0.token.isNativeToken == true }
    }

    var systemImage: String {
        blockchainConfig.systemImage
    }

    var usdValue: Decimal {
        balances.reduce(into: 0) { partialResult, balance in
            partialResult += balance.usdValue
        }
    }

    func setBalance(of token: Token, amount: BigUInt) {
        if let balance = balances.first(where: { $0.token.id == token.id }) {
            balance.amount = amount
        } else {
            let balance = Balance(account: self, amount: amount, token: token)
            balances.append(balance)
        }
    }
}

// MARK: - Mocks

#if DEBUG

extension Account {
    // swiftlint:disable:next function_body_length
    static func mockEth(keyStore: KeyStore) -> Account {
        do {
            let nativeToken = Token(
                address: nil,
                blockchain: nil,
                decimalsCount: 18,
                isNativeToken: true,
                name: "Ether",
                symbol: "ETH"
            )

            let blockchainConfig = try BlockchainConfig(
                blockchain: .ethereum(0xaa36a7),
                displayName: "Ethereum",
                endpointURL: URL(string: "https://ethereum-sepolia-rpc.publicnode.com")!,
                isTestnet: true,
                isUserAdded: false,
                nativeToken: nativeToken,
                networkName: "Ethereum Sepolia",
                systemImage: "eth-logo"
            )

            nativeToken.blockchain = blockchainConfig
            blockchainConfig.tokens.append(nativeToken)

            let accountIndex = keyStore.nextAccountIndex(blockchainConfig.blockchain)
            let account = Account(
                accountIndex: accountIndex,
                address: "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045",
                blockchainConfig: blockchainConfig,
                keyStore: keyStore,
                name: "Ethereum Sepolia #1"
            )

            let nativeBalance = Balance(account: account, amount: 100500, token: nativeToken)
            account.balances.append(nativeBalance)

            let token2Address =
                "0xaf88d065e77c8cc2239327c5edb3a432268e5831"

            let token = Token(
                address: token2Address,
                blockchain: blockchainConfig,
                decimalsCount: 6,
                isNativeToken: false,
                name: "USD Coin",
                symbol: "USDC"
            )

            let balance = Balance(
                account: account,
                amount: 100500,
                token: token
            )

            account.balances.append(balance)

            return account
        } catch {
            fatalError("Cannot create mock account")
        }
    }

    // swiftlint:disable:next function_body_length
    static func mockSui(keyStore: KeyStore) -> Account {
        do {
            let nativeToken = Token(
                address: "0x2::sui::SUI",
                blockchain: nil,
                decimalsCount: 9,
                isNativeToken: true,
                name: "Sui",
                symbol: "SUI"
            )

            let blockchainConfig = try BlockchainConfig(
                blockchain: .sui(.ed25519),
                displayName: "Sui",
                endpointURL: URL(string: "https://fullnode.testnet.sui.io:443")!,
                isTestnet: true,
                isUserAdded: false,
                nativeToken: nativeToken,
                networkName: "Sui Testnet",
                systemImage: "sui-logo"
            )

            nativeToken.blockchain = blockchainConfig
            blockchainConfig.tokens.append(nativeToken)

            let accountIndex = keyStore.nextAccountIndex(blockchainConfig.blockchain)
            let account = Account(
                accountIndex: accountIndex,
                address: "0x5525d71aec7ef111b6648b62e451aa218e3a93821f15f70f3d7e465aa975248a",
                blockchainConfig: blockchainConfig,
                keyStore: keyStore,
                name: "Sui Testnet #1"
            )

            let nativeBalance = Balance(account: account, amount: 100500, token: nativeToken)
            account.balances.append(nativeBalance)

            let tokenAddress =
                "0xa1ec7fc00a6f40db9693ad1415d0c193ad3906494428cf252621037bd7117e29::usdc::USDC"

            let token = Token(
                address: tokenAddress,
                blockchain: blockchainConfig,
                decimalsCount: 6,
                isNativeToken: false,
                name: "USD Coin",
                symbol: "USDC"
            )

            let balance = Balance(
                account: account,
                amount: 100500,
                token: token
            )

            account.balances.append(balance)

            return account
        } catch {
            fatalError("Cannot create mock account")
        }
    }
}

#endif
