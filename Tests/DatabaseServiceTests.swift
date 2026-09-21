import BigInt
import Foundation
import SwiftData
import Testing
import WalletKitTesting
@testable import ReefrWallet

@Suite(.timeLimit(.minutes(1)))
struct DatabaseServiceTests {
    @Test
    func keyStoresCanBeInsertedFetchedRenamedAndDeleted() async throws {
        let service = try makeDatabaseService()
        let keyStore = makeKeyStore(name: "Primary")

        let id = try await service.insertKeyStore(keyStore)
        let inserted = try #require(await service.fetchKeyStore(id: id))

        #expect(inserted.id == id)
        #expect(inserted.name == "Primary")
        #expect(inserted.kind == .local)

        try await service.renameKeyStore(id: id, name: "Renamed")
        #expect(try await service.fetchKeyStore(id: id)?.name == "Renamed")

        try await service.deleteKeyStore(id: id)
        #expect(try await service.fetchKeyStore(id: id) == nil)
    }

    @Test
    func watchOnlyKeyStoreIsCreatedOnceAndThenFetched() async throws {
        let service = try makeDatabaseService()

        let first = try await service.watchOnlyKeyStore()
        let second = try await service.watchOnlyKeyStore()

        #expect(first.kind == .watchOnly)
        #expect(first.name == "Watch-Only")
        #expect(first.id == second.id)
    }

    @Test
    func accountsCanBeInsertedFetchedFilteredRenamedAndDeleted() async throws {
        let service = try makeDatabaseService()
        let keyStoreID = try await service.insertKeyStore(makeKeyStore())
        let keyStore = makeKeyStore(id: keyStoreID)
        let ethereum = WKBlockchain.evm(.ethereum(.mainnet))

        var account = makeAccount(keyStoreID: keyStoreID, blockchain: ethereum)
        account.id = try await service.insertAccount(account, keyStore: keyStore)

        guard let accountId = account.id else {
            throw Error.internalError
        }

        #expect(try await service.fetchAccount(id: accountId) == account)
        #expect(try await service.fetchAccounts(keyStoreId: keyStoreID) == [account])
        #expect(try await service.fetchAccounts(keyStoreId: keyStoreID, blockchain: ethereum) == [account])
        #expect(try await service.fetchAccounts(
            keyStoreId: keyStoreID,
            blockchain: .sui(.testnet)
        ).isEmpty)

        try await service.renameAccount(id: accountId, name: "Renamed Account")
        #expect(try await service.fetchAccount(id: accountId)?.name == "Renamed Account")

        try await service.deleteAccount(id: accountId)
        #expect(try await service.fetchAccount(id: accountId) == nil)
        #expect(try await service.fetchAccounts(keyStoreId: keyStoreID).isEmpty)
    }

    @Test
    func blockchainsRejectDuplicatesAndTokensCanBeFetchedByBlockchain() async throws {
        let service = try makeDatabaseService()
        let blockchain = WKBlockchain.evm(.ethereum(.mainnet))

        _ = try await service.insertBlockchain(blockchain)

        await #expect(throws: Error.alreadyExists) {
            try await service.insertBlockchain(blockchain)
        }

        let token = makeToken(address: "0x0000000000000000000000000000000000000001")
        _ = try await service.insertToken(token, blockchain: blockchain)

        let tokens = try await service.fetchTokens(blockchain: blockchain)
        #expect(tokens.contains { $0.address == token.address })
    }

    @Test
    func transactionsUpsertEffectsAndPersistSyncState() async throws {
        let service = try makeDatabaseService()
        let keyStoreID = try await service.insertKeyStore(makeKeyStore())
        let keyStore = makeKeyStore(id: keyStoreID)
        var account = makeAccount(keyStoreID: keyStoreID, blockchain: .evm(.ethereum(.mainnet)))
        account.id = try await service.insertAccount(account, keyStore: keyStore)
        let token = makeToken(address: "0x0000000000000000000000000000000000000001")

        let transaction = BlockchainTransaction(
            identifier: "0xtransaction",
            blockHeight: 42,
            blockHash: "0xblock",
            timestamp: Date(timeIntervalSince1970: 1),
            sender: account.address,
            status: .confirmed,
            effects: [
                BlockchainTransactionEffect(
                    index: 0,
                    kind: .nativeTransfer,
                    amount: "100",
                    from: account.address,
                    to: "0x0000000000000000000000000000000000000002"
                ),
                BlockchainTransactionEffect(
                    index: 1,
                    kind: .tokenTransfer,
                    assetIdentifier: token.address,
                    amount: "25",
                    from: account.address,
                    to: "0x0000000000000000000000000000000000000002"
                )
            ]
        )
        try await service.saveTransactions([transaction, transaction], for: account)

        let stored = try await service.fetchTransactions(accountId: try #require(account.id))
        #expect(stored.count == 1)
        #expect(stored[0].effects.count == 2)
        #expect(stored[0].effects.contains { effect in
            effect.kind == .nativeTransfer && effect.amount == "100"
        })
        #expect(stored[0].effects.allSatisfy { $0.balance == nil })

        _ = try await service.insertToken(token, blockchain: account.blockchain)
        try await service.saveBalance(Balance(account: account, amount: 25, token: token, usdValue: nil))
        try await service.linkTransactionTokens(for: account)

        let linked = try await service.fetchTransactions(accountId: try #require(account.id))
        #expect(linked[0].effects.compactMap(\.balance).map(\.token.address) == [token.address])

        var state = try await service.transactionSyncState(accountId: try #require(account.id))
        state.initialBackfillHead = 42
        state.currentHead = 43
        state.descendingCursor = Data([1, 2])
        try await service.saveTransactionSyncState(state)

        let restored = try await service.transactionSyncState(accountId: try #require(account.id))
        #expect(restored.initialBackfillHead == 42)
        #expect(restored.currentHead == 43)
        #expect(restored.descendingCursor == Data([1, 2]))
    }

    @Test
    func balancesCanBeSavedFetchedInBatchesAndUpdated() async throws {
        let service = try makeDatabaseService()
        let keyStoreID = try await service.insertKeyStore(makeKeyStore())
        let keyStore = makeKeyStore(id: keyStoreID)
        let blockchain = WKBlockchain.evm(.ethereum(.mainnet))
        var account = makeAccount(keyStoreID: keyStoreID, blockchain: blockchain)
        let accountID = try await service.insertAccount(account, keyStore: keyStore)
        account.id = accountID

        let token = makeToken(address: "0x0000000000000000000000000000000000000001")
        _ = try await service.insertToken(token, blockchain: blockchain)

        let balance = Balance(
            account: account,
            amount: 100,
            token: token,
            usdValue: 12.5
        )
        let balanceID = try await service.saveBalance(balance)

        #expect(try await service.fetchBalances(accountId: accountID).count == 1)
        #expect(try await service.fetchBalances(accountId: accountID).first?.id == balanceID)

        let updatedToken = makeToken(
            address: token.address,
            name: "Updated Token",
            usdPrice: 0.1
        )
        let updatedBalance = Balance(
            account: account,
            amount: 250,
            token: updatedToken,
            usdValue: 25
        )
        try await service.saveBalances([updatedBalance])

        let fetched = try #require(try await service.fetchBalances(accountId: accountID).first)
        #expect(fetched.id == balanceID)
        #expect(fetched.amount == 250)
        #expect(fetched.usdValue == 25)
        #expect(fetched.token.name == "Updated Token")
        #expect(try await service.fetchTokens(account: account).contains {
            $0.address == token.address
        })
    }

    @Test
    func updateBalancesUpdatesExistingBalancesAndInsertsNewTokens() async throws {
        let service = try makeDatabaseService()
        let keyStoreID = try await service.insertKeyStore(makeKeyStore())
        let keyStore = makeKeyStore(id: keyStoreID)
        let blockchain = WKBlockchain.evm(.ethereum(.mainnet))
        var account = makeAccount(keyStoreID: keyStoreID, blockchain: blockchain)
        let accountID = try await service.insertAccount(account, keyStore: keyStore)
        account.id = accountID

        let existingToken = makeToken(
            address: "0x0000000000000000000000000000000000000001",
            usdPrice: 1
        )
        _ = try await service.insertToken(existingToken, blockchain: blockchain)
        try await service.saveBalance(Balance(
            account: account,
            amount: 10,
            token: existingToken,
            usdValue: 10
        ))

        let newToken = makeToken(
            address: "0x0000000000000000000000000000000000000002",
            name: "New Token",
            usdPrice: 3
        )
        try await service.updateBalances(account: account, updates: [
            Balance(account: account, amount: 20, token: existingToken, usdValue: 20),
            Balance(account: account, amount: 30, token: newToken, usdValue: 90)
        ])

        let balances = try await service.fetchBalances(accountId: accountID)
        #expect(balances.count == 2)
        #expect(balances.contains { $0.token.address == existingToken.address && $0.amount == 20 })
        #expect(balances.contains { $0.token.address == newToken.address && $0.amount == 30 })
        #expect(try await service.fetchTokens(blockchain: blockchain).contains {
            $0.address == newToken.address
        })
    }

    @Test
    func deleteAllAccountsKeepsKeyStoresAndRemovesRelatedData() async throws {
        let service = try makeDatabaseService()
        let keyStoreID = try await service.insertKeyStore(makeKeyStore())
        let keyStore = makeKeyStore(id: keyStoreID)
        let blockchain = WKBlockchain.evm(.ethereum(.mainnet))
        var account = makeAccount(keyStoreID: keyStoreID, blockchain: blockchain)
        let accountID = try await service.insertAccount(account, keyStore: keyStore)
        account.id = accountID

        let token = makeToken(address: "0x0000000000000000000000000000000000000001")
        _ = try await service.insertToken(token, blockchain: blockchain)

        let balance = Balance(
            account: account,
            amount: 100,
            token: token,
            usdValue: 12.5
        )
        _ = try await service.saveBalance(balance)
        #expect(try await service.fetchBalances(accountId: accountID).count == 1)

        try await service.deleteAllAccounts()

        #expect(try await service.fetchAccounts(keyStoreId: keyStoreID).isEmpty)
        #expect(try await service.fetchKeyStore(id: keyStoreID) != nil)
        #expect(try await service.fetchAccount(id: accountID) == nil)
        #expect(try await service.fetchBalances(accountId: accountID).isEmpty)
    }

    @Test
    func missingAndInvalidRecordsThrowExpectedErrors() async throws {
        let service = try makeDatabaseService()
        let missingID = try await service.insertKeyStore(makeKeyStore())
        let missingAccountID = try await service.insertKeyStore(makeKeyStore(name: "Other"))
        try await service.deleteKeyStore(id: missingAccountID)

        await #expect(throws: Error.notFound) {
            try await service.renameKeyStore(id: missingAccountID, name: "Missing")
        }

        let account = makeAccount(
            keyStoreID: missingID,
            blockchain: .evm(.ethereum(.mainnet))
        )
        let deletedKeyStoreID = try await service.insertKeyStore(makeKeyStore(name: "Unrelated"))
        try await service.deleteKeyStore(id: deletedKeyStoreID)
        await #expect(throws: Error.notFound) {
            try await service.insertAccount(account, keyStore: makeKeyStore(id: deletedKeyStoreID))
        }

        await #expect(throws: Error.invalidData) {
            try await service.fetchTokens(account: account)
        }
    }
}

extension DatabaseServiceTests {
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

    func makeKeyStore(
        id: PersistentIdentifier? = nil,
        name: String = "Test Key Store"
    ) -> KeyStore {
        KeyStore(
            deviceId: nil,
            id: id,
            kind: .local,
            name: name,
            mnemonicEntropy: Data(repeating: 1, count: 16),
            mnemonicWordlist: .english,
            transport: nil,
            vendor: nil
        )
    }

    func makeAccount(
        keyStoreID: PersistentIdentifier,
        blockchain: WKBlockchain,
        name: String = "Test Account"
    ) -> Account {
        Account(
            accountIndex: 0,
            address: "0x0000000000000000000000000000000000000001",
            blockchain: blockchain,
            derivationPath: nil,
            keyStoreId: keyStoreID,
            name: name
        )
    }

    func makeToken(
        address: String?,
        name: String = "Test Token",
        usdPrice: Decimal? = nil
    ) -> Token {
        Token(
            address: address,
            blockchain: .evm(.ethereum(.mainnet)),
            decimalsCount: 0,
            imageURL: nil,
            isHidden: false,
            isIncludedInBalance: true,
            isNativeToken: false,
            name: name,
            symbol: "TST",
            usdPrice: usdPrice
        )
    }
}
