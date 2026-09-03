import BigInt
import Foundation
import SwiftData
import Testing
import WalletKit
@testable import ReefrWallet

@Suite(.timeLimit(.minutes(1)))
struct BalancesServiceTests {
    @Test
    func updateBalancesPersistsAnvilNativeBalanceAndUsdValuesAggregate() async throws {
        let repositoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let node = try await AnvilNode.start(
            port: 8548,
            workingDirectory: repositoryURL
        )
        defer { node.stop() }

        let databaseService = try makeDatabaseService()
        let balancesService = BalancesService(databaseService: databaseService)

        let keyStoreID = try await databaseService.insertKeyStore(makeKeyStore())
        let keyStore = makeKeyStore(id: keyStoreID)
        let blockchain = WKBlockchain.evm(.custom(node.chainId))
        let account = try await databaseService.insertAccount(
            makeAccount(keyStoreID: keyStoreID, blockchain: blockchain, endpointURL: node.endpoint),
            keyStore: keyStore
        )
        let accountID = try #require(account.id)
        let address = try EthereumAddress(string: account.address)
        let nativeAmount = BigUInt(5_000_000_000_000_000_000)

        try await node.setBalance(address, wei: nativeAmount)
        try await balancesService.updateBalances(account)

        let updatedBalances = try await databaseService.fetchBalances(accountId: accountID)
        let updatedBalance = try #require(updatedBalances.first)

        #expect(updatedBalances.count == 1)
        #expect(updatedBalance.amount == nativeAmount)
        #expect(updatedBalance.token.isNativeToken)
        #expect(try await balancesService.usdValue(accountId: accountID) == 0)
        #expect(try await balancesService.usdValue(keyStoreId: keyStoreID) == 0)

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

        #expect(try await balancesService.usdValue(accountId: accountID) == 10_000)
        #expect(try await balancesService.usdValue(keyStoreId: keyStoreID) == 10_000)
    }

    @Test
    func usdValueThrowsWhenTheAccountOrKeyStoreDoesNotExist() async throws {
        let databaseService = try makeDatabaseService()
        let balancesService = BalancesService(databaseService: databaseService)
        let keyStoreID = try await databaseService.insertKeyStore(makeKeyStore())
        let keyStore = makeKeyStore(id: keyStoreID)
        let account = try await databaseService.insertAccount(
            makeAccount(
                keyStoreID: keyStoreID,
                blockchain: .evm(.custom(31_337)),
                endpointURL: URL(string: "http://localhost:8548")!
            ),
            keyStore: keyStore
        )
        let accountID = try #require(account.id)

        try await databaseService.deleteAccount(id: accountID)
        try await databaseService.deleteKeyStore(id: keyStoreID)

        #expect(try await balancesService.usdValue(accountId: accountID) == 0)
        await #expect(throws: Error.notFound) {
            try await balancesService.usdValue(keyStoreId: keyStoreID)
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
            rawKey: nil,
            transport: nil,
            vendor: nil
        )
    }

    func makeAccount(
        keyStoreID: PersistentIdentifier,
        blockchain: WKBlockchain,
        endpointURL: URL
    ) -> Account {
        Account(
            accountIndex: nil,
            address: "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266",
            blockchain: blockchain,
            derivationPath: nil,
            keyStoreId: keyStoreID,
            name: "Anvil Test Account",
            rpcURLOverride: endpointURL
        )
    }
}
