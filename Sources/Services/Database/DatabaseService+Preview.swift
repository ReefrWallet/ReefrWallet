//
//  DatabaseService+Preview.swift
//  ReefrWallet
//
//  Created by Andrey Yurkevich on 17/09/2026.
//

import SwiftData
import WalletKit

extension DatabaseService {
    func mockAccount(blockchain: Blockchain, keyStore: KeyStore) throws -> Account {
        guard let keyStoreId = keyStore.id else {
            throw Error.invalidData
        }

        var account = Account(
            accountIndex: 0,
            address: "0x0",
            blockchain: blockchain,
            derivationPath: "m/44/60/0/0/0",
            keyStoreId: keyStoreId,
            name: "Ethereum #1"
        )

        account.id = try insertAccount(account, keyStore: keyStore)
        return account
    }

    func mockKeyStore(kind: KeyStore.Kind) throws -> KeyStore {
        var keyStore = switch kind {
        case .local:
            KeyStore(
                deviceId: nil,
                kind: .local,
                name: "Local Key #1",
                transport: nil,
                vendor: nil
            )

        case .trezor:
            KeyStore(
                deviceId: nil,
                kind: .trezor,
                name: "Trezor #1",
                transport: .usb,
                vendor: .trezor
            )

        case .watchOnly:
            try watchOnlyKeyStore()
        }

        if [.local, .trezor].contains(kind) {
            keyStore.id = try insertKeyStore(keyStore)
        }

        return keyStore
    }

    // swiftlint:disable:next function_body_length
    func mockPreviewData() throws {
        let keyStore = try mockKeyStore(kind: .watchOnly)
        let blockchain = Blockchain.evm(.ethereum(.mainnet))
        let account = try mockAccount(blockchain: blockchain, keyStore: keyStore)

        let nativeToken = Token(
            address: nil,
            blockchain: blockchain,
            decimalsCount: 18,
            isHidden: false,
            isNativeToken: true,
            name: "Ether",
            symbol: "ETH"
        )

        let usdcToken = Token(
            address: "0x1",
            blockchain: blockchain,
            decimalsCount: 6,
            isHidden: false,
            isNativeToken: true,
            name: "USD Coin",
            symbol: "USDC"
        )

        let wbtcToken = Token(
            address: "0x2",
            blockchain: blockchain,
            decimalsCount: 8,
            isHidden: false,
            isNativeToken: true,
            name: "Wrapped Bitcoin",
            symbol: "WBTC"
        )

        let nativeBalance = Balance(
            account: account,
            amount: 1000000000000000000,
            token: nativeToken,
            usdValue: 1500.0
        )

        let usdcBalance = Balance(
            account: account,
            amount: 100000000000,
            token: usdcToken,
            usdValue: 0.0098
        )

        let wbtcBalance = Balance(
            account: account,
            amount: 4200000,
            token: wbtcToken,
            usdValue: 65000.0
        )

        try saveBalance(nativeBalance)
        try saveBalance(usdcBalance)
        try saveBalance(wbtcBalance)
    }
}
