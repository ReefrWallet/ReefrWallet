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
import WalletKit

// MARK: - Account

struct Account: Equatable, Hashable, Identifiable, Sendable {
    var id: PersistentIdentifier?

    let accountIndex: UInt64?
    let address: String
    let blockchain: WKBlockchain
    let derivationPath: String?
    // let keyStore: KeyStore
    let name: String
    let signatureScheme: Curve?
    let usdValue: Decimal

    init(
        accountIndex: UInt64?,
        address: String,
        blockchain: WKBlockchain,
        derivationPath: String?,
        // keyStore: KeyStore,
        name: String,
        signatureScheme: Curve? = nil,
        usdValue: Decimal = .zero
    ) {
        id = nil

        self.accountIndex = accountIndex
        self.address = address
        self.blockchain = blockchain
        self.derivationPath = derivationPath
        // self.keyStore = keyStore
        self.name = name
        self.signatureScheme = signatureScheme
        self.usdValue = usdValue
    }
}

// MARK: - AccountModel

@Model
final class AccountModel {
    var accountIndex: UInt64?
    var address: String
    var derivationPath: String?
    var name: String
    var signatureScheme: String

    @Relationship(deleteRule: .cascade, inverse: \BalanceModel.account)
    var balances: [BalanceModel]

    @Relationship
    var blockchain: BlockchainModel

    @Relationship
    var keyStore: KeyStoreModel

    init(
        accountIndex: UInt64? = nil,
        address: String,
        blockchain: BlockchainModel,
        derivationPath: String? = nil,
        keyStore: KeyStoreModel,
        name: String,
        signatureScheme: Curve? = nil
    ) {
        guard accountIndex != nil || keyStore.isWatchOnly else {
            preconditionFailure("Missing account index")
        }

        self.accountIndex = accountIndex
        self.address = address
        self.balances = []
        self.blockchain = blockchain
        self.derivationPath = derivationPath
        self.keyStore = keyStore
        self.name = name

        self.signatureScheme = signatureScheme?.rawValue ?? ""
    }
}

// MARK: - Init

extension Account {
    init(model: AccountModel) throws {
        id = model.id
        accountIndex = model.accountIndex
        address = model.address
        blockchain = model.blockchain.blockchain
        derivationPath = model.derivationPath
        // keyStore = try KeyStore(model: keyStoreModel)
        name = model.name
        signatureScheme = Curve(rawValue: model.signatureScheme)
        usdValue = model.usdValue
    }
}

extension AccountModel {
    convenience init(account: Account, blockchain: BlockchainModel, keyStore: KeyStoreModel) throws {
        self.init(
            accountIndex: account.accountIndex,
            address: account.address,
            blockchain: blockchain,
            derivationPath: account.derivationPath,
            keyStore: keyStore,
            name: account.name,
            signatureScheme: account.signatureScheme
        )
    }
}

// MARK: - Comparable

extension AccountModel: Comparable {
    static func < (lhs: AccountModel, rhs: AccountModel) -> Bool {
        (lhs.blockchain.blockchain.displayName, lhs.accountIndex ?? 0)
            < (rhs.blockchain.blockchain.displayName, rhs.accountIndex ?? 0)
    }
}

extension AccountModel {
    var usdValue: Decimal {
        balances.reduce(into: 0) { partialResult, balance in
            partialResult += balance.usdValue
        }
    }
}

// MARK: - Mocks

/* #if DEBUG

extension Account {
    static func mockEth(keyStore: KeyStoreModel) -> Account {
        do {
            let nativeToken = TokenModel(
                address: nil,
                blockchain: nil,
                decimalsCount: 18,
                isNativeToken: true,
                name: "Ether",
                symbol: "ETH"
            )

            let blockchain = try BlockchainModel(
                blockchain: .ethereum(0xaa36a7),
                displayName: "Ethereum",
                endpointURL: URL(string: "https://ethereum-sepolia-rpc.publicnode.com")!,
                isTestnet: true,
                nativeToken: nativeToken,
                systemImage: "eth-logo"
            )

            nativeToken.blockchain = blockchain
            blockchain.tokens.append(nativeToken)

            let account = AccountModel(
                accountIndex: 1,
                address: "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045",
                blockchain: blockchain,
                keyStore: keyStore,
                name: "Ethereum Sepolia #1"
            )

            let nativeBalance = BalanceModel(account: account, amount: 100500, token: nativeToken)
            account.balances.append(nativeBalance)

            let token2Address =
                "0xaf88d065e77c8cc2239327c5edb3a432268e5831"

            let token = TokenModel(
                address: token2Address,
                blockchain: blockchain,
                decimalsCount: 6,
                isNativeToken: false,
                name: "USD Coin",
                symbol: "USDC"
            )

            let balance = BalanceModel(
                account: account,
                amount: 100500,
                token: token
            )

            account.balances.append(balance)
            return try! Account(model: account) // swiftlint:disable:this force_try
        } catch {
            fatalError("Cannot create mock account")
        }
    }

    static func mockSui(keyStore: KeyStoreModel) throws -> Account {
        do {
            let nativeToken = TokenModel(
                address: "0x2::sui::SUI",
                blockchain: nil,
                decimalsCount: 9,
                isNativeToken: true,
                name: "Sui",
                symbol: "SUI"
            )

            let blockchain = try BlockchainModel(
                blockchain: .sui(.testnet),
                displayName: "Sui",
                endpointURL: URL(string: "https://fullnode.testnet.sui.io:443")!,
                isTestnet: true,
                nativeToken: nativeToken,
                systemImage: "sui-logo"
            )

            nativeToken.blockchain = blockchain
            blockchain.tokens.append(nativeToken)

            let account = AccountModel(
                accountIndex: 1,
                address: "0x5525d71aec7ef111b6648b62e451aa218e3a93821f15f70f3d7e465aa975248a",
                blockchain: blockchain,
                keyStore: keyStore,
                name: "Sui Testnet #1"
            )

            let nativeBalance = BalanceModel(account: account, amount: 100500, token: nativeToken)
            account.balances.append(nativeBalance)

            let tokenAddress =
                "0xa1ec7fc00a6f40db9693ad1415d0c193ad3906494428cf252621037bd7117e29::usdc::USDC"

            let token = TokenModel(
                address: tokenAddress,
                blockchain: blockchain,
                decimalsCount: 6,
                isNativeToken: false,
                name: "USD Coin",
                symbol: "USDC"
            )

            let balance = BalanceModel(
                account: account,
                amount: 100500,
                token: token
            )

            account.balances.append(balance)
            return try! Account(model: account) // swiftlint:disable:this force_try
        } catch {
            fatalError("Cannot create mock account")
        }
    }
}
#endif */
