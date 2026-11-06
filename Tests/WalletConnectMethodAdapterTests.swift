//
//  WalletConnectMethodAdapterTests.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 17.10.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation
import SwiftData
import Testing
import WalletKit

@testable import ReefrWallet

@Suite
struct WalletConnectMethodAdapterTests {
    private func makeAccount(_ blockchain: Blockchain, address: String) throws -> ReefrWallet.Account {
        let container = try ModelContainer(
            for: KeyStoreModel.self, AccountModel.self, BlockchainModel.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )

        let keyStoreId = KeyStoreModel(
            .watchOnly,
            deviceId: nil,
            name: "t",
            mnemonicEntropy: nil,
            mnemonicWordlist: nil,
            transport: nil,
            vendor: nil
        ).persistentModelID

        _ = container
        return ReefrWallet.Account(
            address: address,
            blockchain: blockchain,
            derivationPath: nil,
            keyStoreId: keyStoreId,
            name: "a"
        )
    }

    @Test
    func passesEthereumMethodsThrough() throws {
        let account = try makeAccount(.evm(EVMBlockchain(chainId: 1)), address: "0xabc")
        let params = JSONValue.array([.string("0x01"), .string("0xabc")])
        let adapted = try WalletConnectMethodAdapter.adaptRequest(
            method: "personal_sign", params: params, namespace: .ethereum, account: account
        )

        #expect(adapted == WalletConnectMethodAdapter.Adapted(method: "personal_sign", params: params))
    }

    @Test
    func rejectsUnadvertisedMethods() throws {
        let account = try makeAccount(.evm(EVMBlockchain(chainId: 1)), address: "0xabc")

        #expect(throws: DappError.self) {
            try WalletConnectMethodAdapter.adaptRequest(
                method: "eth_sign", params: .array([]), namespace: .ethereum, account: account
            )
        }
    }

    @Test
    func convertsSolanaMessageFromBase58ToBase64() throws {
        let account = try makeAccount(.solana(.mainnet), address: "11111111111111111111111111111111")
        let message = Data("hello".utf8)
        let params = JSONValue.object(["pubkey": .string(account.address), "message": .string(Base58.encode(message))])
        let adapted = try WalletConnectMethodAdapter.adaptRequest(
            method: "solana_signMessage", params: params, namespace: .solana, account: account
        )

        #expect(adapted.method == "signMessage")
        #expect(adapted.params["message"]?.stringValue == message.base64EncodedString())
        #expect(adapted.params["account"]?["address"]?.stringValue == account.address)
    }

    @Test
    func returnsSolanaSignatureAsBase58() throws {
        let signature = Data(repeating: 7, count: 64)
        let result = try WalletConnectMethodAdapter.adaptResult(
            method: "solana_signMessage",
            result: .object(["signature": .string(signature.base64EncodedString())]),
            namespace: .solana,
            request: .null
        )

        #expect(result["signature"]?.stringValue == Base58.encode(signature))
    }

    @Test
    func hexEncodesTronMessage() throws {
        let account = try makeAccount(.tron(.mainnet), address: "T")
        let adapted = try WalletConnectMethodAdapter.adaptRequest(
            method: "tron_signMessage", params: .object(["message": .string("hi")]), namespace: .tron, account: account
        )

        #expect(adapted.params["message"]?.stringValue == "6869")
    }
}
