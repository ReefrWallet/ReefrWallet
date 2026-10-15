import BigInt
import Foundation
import SwiftData
import Testing
import WalletKitTesting
@testable import ReefrWallet

@Suite(.timeLimit(.minutes(1)))
struct BalancesServiceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TRONGRID_API_KEY"] != nil))
    func updateBalancesPersistsFundedNileNativeBalance() async throws {
        let apiKey = try #require(ProcessInfo.processInfo.environment["TRONGRID_API_KEY"])
        let previousAPIKey = UserDefaults.standard.string(forKey: "TronGridAPIKey")
        UserDefaults.standard.set(apiKey, forKey: "TronGridAPIKey")
        defer { UserDefaults.standard.set(previousAPIKey, forKey: "TronGridAPIKey") }

        let databaseService = try makeDatabaseService()
        let balancesService = BalancesService(databaseService: databaseService)
        let keyStoreId = try await databaseService.insertKeyStore(makeKeyStore())
        let keyStore = makeKeyStore(id: keyStoreId)
        var account = makeTronAccount(keyStoreId: keyStoreId)
        account.id = try await databaseService.insertAccount(account, keyStore: keyStore)
        let accountId = try #require(account.id)

        for token in tronTestTokens {
            _ = try await databaseService.insertToken(token, blockchain: account.blockchain)
        }

        try await databaseService.saveTransactions(
            [
                BlockchainTransaction(
                    identifier: "tron-token-candidates",
                    status: .confirmed,
                    effects: tronTestTokens.enumerated().map { index, token in
                        BlockchainTransactionEffect(
                            index: UInt64(index),
                            kind: .tokenTransfer,
                            assetIdentifier: token.address,
                            amount: "1"
                        )
                    }
                )
            ],
            for: account
        )

        try await balancesService.updateBalances(account)

        let balances = try await databaseService.fetchBalances(accountId: accountId)
        let nativeBalance = try #require(balances.first(where: { $0.token.isNativeToken }))
        #expect(nativeBalance.amount > 0)
        #expect(nativeBalance.token.symbol == "TRX")
        for token in tronTestTokens {
            let balance = try #require(balances.first(where: { $0.token.address == token.address }))
            #expect(balance.amount > 0, "Expected a positive \(token.symbol) balance for the Nile test account.")
        }
    }

    @Test(.localNode)
    func updateBalancesPersistsAnvilNativeBalanceAndUsdValuesAggregate() async throws {
        let repositoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let node = try await EthereumNode.start(
            port: 8548,
            workingDirectory: repositoryURL
        )

        defer { node.stop() }

        let databaseService = try makeDatabaseService()
        let balancesService = BalancesService(databaseService: databaseService)

        let keyStoreId = try await databaseService.insertKeyStore(makeKeyStore())
        let keyStore = makeKeyStore(id: keyStoreId)
        let blockchain = Blockchain.evm(.custom(node.chainId))
        var account = makeAccount(keyStoreId: keyStoreId, blockchain: blockchain, endpointURL: node.endpoint)
        let accountId = try await databaseService.insertAccount(account, keyStore: keyStore)
        account.id = accountId

        let address = try EthereumAddress(string: account.address)
        let nativeAmount = BigUInt(5_000_000_000_000_000_000)

        try await node.setBalance(address, wei: nativeAmount)
        try await balancesService.updateBalances(account)

        let updatedBalances = try await databaseService.fetchBalances(accountId: accountId)
        let updatedBalance = try #require(updatedBalances.first)

        #expect(updatedBalances.count == 1)
        #expect(updatedBalance.amount == nativeAmount)
        #expect(updatedBalance.token.isNativeToken)
        #expect(try await balancesService.usdValue(accountId: accountId) == 0)
        #expect(try await balancesService.usdValue(keyStoreId: keyStoreId) == 0)

        let pricedNativeToken = Token(
            address: nil,
            blockchain: blockchain,
            decimalsCount: 18,
            imageURL: nil,
            isHidden: false,
            isIncludedInBalance: true,
            isNativeToken: true,
            name: updatedBalance.token.name,
            symbol: updatedBalance.token.symbol,
            usdPrice: 2_000
        )

        try await databaseService.saveBalance(Balance(
            account: account,
            amount: nativeAmount,
            token: pricedNativeToken,
            usdValue: nil
        ))

        #expect(try await balancesService.usdValue(accountId: accountId) == 10_000)
        #expect(try await balancesService.usdValue(keyStoreId: keyStoreId) == 10_000)
    }

    @Test
    func usdValueThrowsWhenTheAccountOrKeyStoreDoesNotExist() async throws {
        let databaseService = try makeDatabaseService()
        let balancesService = BalancesService(databaseService: databaseService)
        let keyStoreId = try await databaseService.insertKeyStore(makeKeyStore())
        let keyStore = makeKeyStore(id: keyStoreId)

        var account = makeAccount(
            keyStoreId: keyStoreId,
            blockchain: .evm(.custom(31_337)),
            endpointURL: URL(string: "http://localhost:8548")!
        )

        account.id = try await databaseService.insertAccount(account, keyStore: keyStore)
        let accountId = try #require(account.id)

        try await databaseService.deleteAccount(id: accountId)
        try await databaseService.deleteKeyStore(id: keyStoreId)

        await #expect(throws: Error.notFound) {
            try await balancesService.usdValue(accountId: accountId)
        }

        await #expect(throws: Error.notFound) {
            try await balancesService.usdValue(keyStoreId: keyStoreId)
        }
    }
}

private extension BalancesServiceTests {
    func makeDatabaseService() throws -> DatabaseService {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: AccountModel.self,
                BalanceModel.self,
                BlockchainModel.self,
                KeyStoreModel.self,
                TokenModel.self,
                SavedAddressModel.self,
                WalletTransactionModel.self,
                WalletTransactionEffectModel.self,
                WalletTransactionSyncStateModel.self,
            configurations: configuration
        )

        return DatabaseService(modelContainer: container)
    }

    func makeKeyStore(id: PersistentIdentifier? = nil) -> KeyStore {
        KeyStore(
            deviceId: nil,
            id: id,
            kind: .watchOnly,
            name: "Anvil Test Key Store",
            transport: nil,
            vendor: nil
        )
    }

    func makeAccount(
        keyStoreId: PersistentIdentifier,
        blockchain: Blockchain,
        endpointURL: URL
    ) -> ReefrWallet.Account {
        Account(
            accountIndex: nil,
            address: "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266",
            blockchain: blockchain,
            derivationPath: nil,
            keyStoreId: keyStoreId,
            name: "Anvil Test Account",
            rpcURLOverride: endpointURL
        )
    }

    func makeTronAccount(keyStoreId: PersistentIdentifier) -> ReefrWallet.Account {
        Account(
            accountIndex: nil,
            address: "TGtcCdz2aV9vvCEtQL5BY8z2BnLi4oJ3sK",
            blockchain: .tron(.testnet),
            derivationPath: nil,
            keyStoreId: keyStoreId,
            name: "Funded Nile Watch-Only"
        )
    }

    var tronTestTokens: [Token] {
        [
            Token(
                address: "TF17BgPaZYbz8oxbjhriubPDsA7ArKoLX3",
                blockchain: .tron(.testnet),
                decimalsCount: 18,
                imageURL: nil,
                isHidden: false,
                isIncludedInBalance: true,
                isNativeToken: false,
                name: "JUST",
                symbol: "JST",
                usdPrice: nil
            ),
            Token(
                address: "TXYZopYRdj2D9XRtbG411XZZ3kM5VkAeBf",
                blockchain: .tron(.testnet),
                decimalsCount: 6,
                imageURL: nil,
                isHidden: false,
                isIncludedInBalance: true,
                isNativeToken: false,
                name: "Tether USD",
                symbol: "USDT",
                usdPrice: nil
            )
        ]
    }
}
