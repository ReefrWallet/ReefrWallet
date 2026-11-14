import BigInt
import Foundation
import SwiftData
import Testing
import WalletKit
@testable import ReefrWallet

@Suite(.timeLimit(.minutes(1)))
struct DatabaseServiceTests { // swiftlint:disable:this type_body_length
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
    func duplicateKeyStoreNamesAreNumbered() async throws {
        let service = try makeDatabaseService()
        var names: [String] = []

        for _ in 0..<3 {
            let id = try await service.insertKeyStore(makeKeyStore(name: "Local Key"))
            try await names.append(#require(service.fetchKeyStore(id: id)).name)
        }

        let otherId = try await service.insertKeyStore(makeKeyStore(name: "Trezor Safe 3"))

        #expect(names == ["Local Key", "Local Key (#2)", "Local Key (#3)"])
        #expect(try await service.fetchKeyStore(id: otherId)?.name == "Trezor Safe 3")
    }

    @Test
    func secretKindRoundTripsAndStoresWithoutOneReadAsBip39() async throws {
        let service = try makeDatabaseService()

        let slip39Id = try await service.insertKeyStore(KeyStore(
            deviceId: nil,
            kind: .local,
            name: "Slip39",
            sealedEntropy: Data(repeating: 2, count: 16),
            secretKind: .slip39,
            transport: nil,
            vendor: nil
        ))
        let bip39Id = try await service.insertKeyStore(makeKeyStore(name: "Bip39"))

        #expect(try await service.fetchKeyStore(id: slip39Id)?.secretKind == .slip39)
        #expect(try await service.fetchKeyStore(id: bip39Id)?.secretKind == .bip39)
    }

    @Test
    func aCancelledInsertSavesNothing() async throws {
        let service = try makeDatabaseService()

        let task = Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            return (try? await service.insertKeyStore(makeKeyStore(name: "Cancelled"))) != nil
        }

        #expect(await task.value == false)
        #expect(try await service.keyStoreCount() == 0)
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
        let keyStoreId = try await service.insertKeyStore(makeKeyStore())
        let keyStore = makeKeyStore(id: keyStoreId)
        let ethereum = Blockchain.evm(.ethereum(.mainnet))

        var account = makeAccount(keyStoreId: keyStoreId, blockchain: ethereum)
        account.id = try await service.insertAccount(account, keyStore: keyStore)

        guard let accountId = account.id else {
            throw ReefrError.internalError
        }

        #expect(try await service.fetchAccount(id: accountId) == account)
        #expect(try await service.fetchAccounts(keyStoreId: keyStoreId) == [account])
        #expect(try await service.fetchAccounts(keyStoreId: keyStoreId, blockchain: ethereum) == [account])
        #expect(try await service.fetchAccounts(
            keyStoreId: keyStoreId,
            blockchain: .sui(.testnet)
        ).isEmpty)

        try await service.renameAccount(id: accountId, name: "Renamed Account")
        #expect(try await service.fetchAccount(id: accountId)?.name == "Renamed Account")

        try await service.deleteAccount(id: accountId)
        #expect(try await service.fetchAccount(id: accountId) == nil)
        #expect(try await service.fetchAccounts(keyStoreId: keyStoreId).isEmpty)
    }

    @Test
    func deletingAccountRemovesItsBalancesAndLinkedTransactions() async throws {
        let service = try makeDatabaseService()
        let keyStoreId = try await service.insertKeyStore(makeKeyStore())
        let keyStore = makeKeyStore(id: keyStoreId)
        var account = makeAccount(keyStoreId: keyStoreId, blockchain: .evm(.ethereum(.mainnet)))
        let accountId = try await service.insertAccount(account, keyStore: keyStore)
        account.id = accountId
        let token = makeToken(address: "0x0000000000000000000000000000000000000001")
        _ = try await service.saveBalance(Balance(account: account, amount: 25, token: token, usdValue: nil))
        try await service.saveTransactions([
            BlockchainTransaction(
                identifier: "0xtransaction",
                status: .confirmed,
                effects: [
                    BlockchainTransactionEffect(index: 0, kind: .tokenTransfer, assetIdentifier: token.address)
                ]
            )
        ], for: account)
        let transactions = try await service.fetchTransactions(accountId: accountId)
        #expect(transactions.first?.effects.first?.balance != nil)

        try await service.deleteAccount(id: accountId)

        let reader = DatabaseService(modelContainer: service.modelContainer)
        #expect(try await reader.fetchAccount(id: accountId) == nil)
        #expect(try await reader.fetchAccounts(keyStoreId: keyStoreId).isEmpty)
        #expect(try await reader.fetchBalances(accountId: accountId).isEmpty)
        #expect(try await reader.fetchTransactions(accountId: accountId).isEmpty)
    }

    @Test
    func deletingAccountPrunesOnlyUnusedTokensOnItsBlockchain() async throws {
        let service = try makeDatabaseService()
        let blockchain = Blockchain.evm(.ethereum(.mainnet))
        let otherBlockchain = Blockchain.evm(.ethereum(.sepolia))
        let removed = try await makeStakingAccount(service, blockchain: blockchain, address: "removed")
        let remaining = try await makeStakingAccount(service, blockchain: blockchain, address: "remaining")
        let removedId = try #require(removed.id)
        let remainingId = try #require(remaining.id)
        _ = try await service.insertBlockchain(otherBlockchain)

        let orphan = makeToken(address: "0xorphan")
        let balanceOnly = makeToken(address: "0xbalance")
        let approvalOnly = makeToken(address: "0xapproval")
        let stakingOnly = makeToken(address: "0xstaking")
        let removedBalance = makeToken(address: "0xremoved")
        _ = try await service.insertToken(orphan, blockchain: blockchain)
        _ = try await service.insertToken(orphan, blockchain: otherBlockchain)
        _ = try await service.saveBalance(Balance(account: removed, amount: 25, token: removedBalance, usdValue: nil))
        _ = try await service.saveBalance(Balance(account: remaining, amount: 25, token: balanceOnly, usdValue: nil))
        try await service.replaceApprovals(
            account: remaining,
            updates: [ApprovalUpdate(allowance: 1, approvedAt: nil, spender: "0xspender", token: approvalOnly)]
        )

        let stakingTokenId = try await service.insertToken(stakingOnly, blockchain: blockchain)
        try await service.saveStakingState(
            accountId: remainingId,
            state: stakingPosition(),
            representatives: [:],
            startedAt: .now
        )

        try await service.assignTestStakingToken(stakingTokenId, accountId: remainingId)
        try await service.deleteAccount(id: removedId)

        let reader = DatabaseService(modelContainer: service.modelContainer)
        let tokens = try await reader.fetchTokens(blockchain: blockchain)
        #expect(tokens.contains { $0.isNativeToken })
        #expect(Set(tokens.compactMap(\.address)) == ["0xbalance", "0xapproval", "0xstaking"])
        #expect(try await reader.fetchStaking(accountId: remainingId)?.tokenId == stakingTokenId)
        #expect(try await reader.fetchToken(tokenAddress: "0xorphan", blockchain: otherBlockchain) != nil)
    }

    @Test
    func cancelledBackfillPageLeavesHistoryAndCursorUntouched() async throws {
        let service = try makeDatabaseService()
        let keyStore = try await service.watchOnlyKeyStore()
        let keyStoreId = try #require(keyStore.id)
        var account = makeAccount(keyStoreId: keyStoreId, blockchain: .evm(.ethereum(.mainnet)))
        let accountId = try await service.insertAccount(account, keyStore: keyStore)
        account.id = accountId
        let savedAccount = account
        var state = WalletTransactionSyncState(accountId: accountId)
        state.descendingCursor = Data("next".utf8)
        let nextState = state

        let page = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await service.saveTransactions(
                [BlockchainTransaction(identifier: "late-page", status: .confirmed)],
                for: savedAccount,
                syncState: nextState
            )
        }

        await #expect(throws: CancellationError.self) {
            try await page.value
        }

        #expect(try await service.fetchTransactions(accountId: accountId).isEmpty)
        #expect(try await service.transactionSyncState(accountId: accountId).descendingCursor == nil)
    }

    @Test
    func blockchainsRejectDuplicatesAndTokensCanBeFetchedByBlockchain() async throws {
        let service = try makeDatabaseService()
        let blockchain = Blockchain.evm(.ethereum(.mainnet))

        _ = try await service.insertBlockchain(blockchain)

        await #expect(throws: ReefrError.alreadyExists) {
            try await service.insertBlockchain(blockchain)
        }

        let token = makeToken(address: "0x0000000000000000000000000000000000000001")
        _ = try await service.insertToken(token, blockchain: blockchain)

        let tokens = try await service.fetchTokens(blockchain: blockchain)
        #expect(tokens.contains { $0.address == token.address })
    }

    @Test
    func accountTokensIncludeItsTransferAssetsButExcludeOtherAccountsAssets() async throws {
        let service = try makeDatabaseService()
        let blockchain = Blockchain.evm(.ethereum(.mainnet))
        let keyStoreId = try await service.insertKeyStore(makeKeyStore())
        let keyStore = makeKeyStore(id: keyStoreId)
        var firstAccount = makeAccount(keyStoreId: keyStoreId, blockchain: blockchain)
        var secondAccount = makeAccount(keyStoreId: keyStoreId, blockchain: blockchain)
        firstAccount.id = try await service.insertAccount(firstAccount, keyStore: keyStore)
        secondAccount.id = try await service.insertAccount(secondAccount, keyStore: keyStore)

        let firstToken = makeToken(address: "0x0000000000000000000000000000000000000001")
        let secondToken = makeToken(address: "0x0000000000000000000000000000000000000002")
        _ = try await service.insertToken(firstToken, blockchain: blockchain)
        _ = try await service.insertToken(secondToken, blockchain: blockchain)
        try await service.saveTransactions([
            BlockchainTransaction(
                identifier: "0xfirst-account-transfer",
                status: .confirmed,
                effects: [
                    BlockchainTransactionEffect(
                        index: 0,
                        kind: .tokenTransfer,
                        assetIdentifier: firstToken.address,
                        amount: "1"
                    )
                ]
            )
        ], for: firstAccount)

        let tokens = try await service.fetchTokens(account: firstAccount)

        #expect(tokens.contains { $0.isNativeToken })
        #expect(tokens.contains { $0.address == firstToken.address })
        #expect(!tokens.contains { $0.address == secondToken.address })
    }

    @Test // swiftlint:disable:next function_body_length
    func transactionsUpsertEffectsAndPersistSyncState() async throws {
        let service = try makeDatabaseService()
        let keyStoreId = try await service.insertKeyStore(makeKeyStore())
        let keyStore = makeKeyStore(id: keyStoreId)
        var account = makeAccount(keyStoreId: keyStoreId, blockchain: .evm(.ethereum(.mainnet)))
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

        try await service.deleteAllTransactions()

        #expect(try await service.fetchTransactions(accountId: try #require(account.id)).isEmpty)
        let resetState = try await service.transactionSyncState(accountId: try #require(account.id))
        #expect(resetState.initialBackfillHead == nil)
        #expect(resetState.currentHead == nil)
        #expect(resetState.descendingCursor == nil)
    }

    @Test
    func approvalPagesKeepStableOrderAcrossEqualDates() async throws {
        let service = try makeDatabaseService()
        let keyStoreId = try await service.insertKeyStore(makeKeyStore())
        let keyStore = makeKeyStore(id: keyStoreId)
        var account = makeAccount(keyStoreId: keyStoreId, blockchain: .evm(.ethereum(.mainnet)))
        account.id = try await service.insertAccount(account, keyStore: keyStore)
        let addresses = ["0x0000000000000000000000000000000000000001", "0x0000000000000000000000000000000000000002"]
        let spender = "0x0000000000000000000000000000000000000003"
        try await service.replaceApprovals(
            account: account,
            updates: addresses.reversed().map {
                ApprovalUpdate(allowance: 1, approvedAt: nil, spender: spender, token: makeToken(address: $0))
            }
        )

        let first = try await service.fetchApprovalPage(account: account, offset: 0, limit: 1)
        let second = try await service.fetchApprovalPage(account: account, offset: 1, limit: 1)

        #expect(first.rows.map(\.token.address) == [addresses[0]])
        #expect(first.hasMore)
        #expect(second.rows.map(\.token.address) == [addresses[1]])
        #expect(!second.hasMore)
    }

    @Test
    func approvalCountCoversEveryStoredApprovalNotJustOnePage() async throws {
        let service = try makeDatabaseService()
        let keyStoreId = try await service.insertKeyStore(makeKeyStore())
        let keyStore = makeKeyStore(id: keyStoreId)
        var account = makeAccount(keyStoreId: keyStoreId, blockchain: .evm(.ethereum(.mainnet)))
        account.id = try await service.insertAccount(account, keyStore: keyStore)
        let spender = "0x0000000000000000000000000000000000000003"
        try await service.replaceApprovals(
            account: account,
            updates: (1...45).map {
                ApprovalUpdate(
                    allowance: 1,
                    approvedAt: nil,
                    spender: spender,
                    token: makeToken(address: String(format: "0x%040x", $0))
                )
            }
        )

        #expect(try await service.approvalCount(account: account) == 45)
        #expect(try await service.fetchApprovalPage(account: account, offset: 0, limit: 40).rows.count == 40)
    }

    @Test
    func transactionPagesContinuePastFormerDisplayLimit() async throws {
        let service = try makeDatabaseService()
        let keyStore = try await service.watchOnlyKeyStore()
        let keyStoreId = try #require(keyStore.id)
        var account = makeAccount(keyStoreId: keyStoreId, blockchain: .evm(.ethereum(.mainnet)))
        let accountId = try await service.insertAccount(account, keyStore: keyStore)
        account.id = accountId

        for start in stride(from: 0, to: 1_001, by: 40) {
            let transactions = (start..<min(start + 40, 1_001)).map {
                BlockchainTransaction(identifier: "tx-\($0)", status: .confirmed)
            }

            try await service.saveTransactions(transactions, for: account)
        }

        let afterLimit = try await service.fetchTransactionPage(accountId: accountId, offset: 500, limit: 40)
        let last = try await service.fetchTransactionPage(accountId: accountId, offset: 1_000, limit: 40)

        #expect(try await service.transactionCount(accountId: accountId) == 1_001)
        #expect(afterLimit.rows.count == 40)
        #expect(afterLimit.hasMore)
        #expect(last.rows.count == 1)
        #expect(!last.hasMore)
    }

    @Test
    func transactionPagesKeepStableOrderAcrossEqualDates() async throws {
        let service = try makeDatabaseService()
        let keyStoreId = try await service.insertKeyStore(makeKeyStore())
        let keyStore = makeKeyStore(id: keyStoreId)
        var account = makeAccount(keyStoreId: keyStoreId, blockchain: .evm(.ethereum(.mainnet)))
        account.id = try await service.insertAccount(account, keyStore: keyStore)
        let accountId = try #require(account.id)
        try await service.saveTransactions(
            ["c", "a", "b"].map { BlockchainTransaction(identifier: $0, status: .confirmed) },
            for: account
        )

        let first = try await service.fetchTransactionPage(accountId: accountId, offset: 0, limit: 2)
        let second = try await service.fetchTransactionPage(accountId: accountId, offset: 2, limit: 2)

        #expect(first.rows.map(\.identifier) == ["a", "b"])
        #expect(first.hasMore)
        #expect(second.rows.map(\.identifier) == ["c"])
        #expect(!second.hasMore)
    }

    @Test
    func savingTransactionsAcrossCallsUpdatesInPlaceInsteadOfDuplicating() async throws {
        let service = try makeDatabaseService()
        let keyStoreId = try await service.insertKeyStore(makeKeyStore())
        let keyStore = makeKeyStore(id: keyStoreId)
        var account = makeAccount(keyStoreId: keyStoreId, blockchain: .evm(.ethereum(.mainnet)))
        account.id = try await service.insertAccount(account, keyStore: keyStore)
        let accountId = try #require(account.id)

        try await service.saveTransactions(
            [BlockchainTransaction(identifier: "0xoverlap", status: .unconfirmed)],
            for: account
        )

        try await service.saveTransactions(
            [BlockchainTransaction(identifier: "0xoverlap", status: .confirmed)],
            for: account
        )

        let stored = try await service.fetchTransactions(accountId: accountId)
        #expect(stored.count == 1)
        #expect(stored[0].status == .confirmed)
    }

    @Test
    func savingTransactionsWithSyncStateWritesBothInOneCall() async throws {
        let service = try makeDatabaseService()
        let keyStoreId = try await service.insertKeyStore(makeKeyStore())
        let keyStore = makeKeyStore(id: keyStoreId)
        var account = makeAccount(keyStoreId: keyStoreId, blockchain: .evm(.ethereum(.mainnet)))
        account.id = try await service.insertAccount(account, keyStore: keyStore)
        let accountId = try #require(account.id)

        var state = try await service.transactionSyncState(accountId: accountId)
        state.currentHead = 99
        state.backfillComplete = true

        try await service.saveTransactions(
            [BlockchainTransaction(identifier: "0xcombined", status: .confirmed)],
            for: account,
            syncState: state
        )

        let stored = try await service.fetchTransactions(accountId: accountId)
        #expect(stored.count == 1)

        let restored = try await service.transactionSyncState(accountId: accountId)
        #expect(restored.currentHead == 99)
        #expect(restored.backfillComplete == true)
    }

    @Test
    func savingLargeTransactionBatchStaysFast() async throws {
        let service = try makeDatabaseService()
        let keyStoreId = try await service.insertKeyStore(makeKeyStore())
        let keyStore = makeKeyStore(id: keyStoreId)
        var account = makeAccount(keyStoreId: keyStoreId, blockchain: .evm(.ethereum(.mainnet)))
        account.id = try await service.insertAccount(account, keyStore: keyStore)
        let accountId = try #require(account.id)

        let transactions = (0..<500).map { index in
            BlockchainTransaction(
                identifier: "0xtx\(index)",
                blockHeight: UInt64(index),
                status: .confirmed,
                effects: [
                    BlockchainTransactionEffect(
                        index: 0,
                        kind: .nativeTransfer,
                        amount: "1",
                        from: account.address,
                        to: "0x0000000000000000000000000000000000000002"
                    ),
                    BlockchainTransactionEffect(
                        index: 1,
                        kind: .tokenTransfer,
                        assetIdentifier: "0x0000000000000000000000000000000000000003",
                        amount: "2",
                        from: account.address,
                        to: "0x0000000000000000000000000000000000000002"
                    )
                ]
            )
        }

        let clock = ContinuousClock()
        let start = clock.now
        try await service.saveTransactions(transactions, for: account)
        let elapsed = clock.now - start

        #expect(try await service.fetchTransactions(accountId: accountId).count == 500)
        // A regression back to one fetch per row would take this from tens of
        // milliseconds to multiple seconds for a batch this size.
        #expect(elapsed < .seconds(2))
    }

    @Test
    func balancesCanBeSavedFetchedInBatchesAndUpdated() async throws {
        let service = try makeDatabaseService()
        let keyStoreId = try await service.insertKeyStore(makeKeyStore())
        let keyStore = makeKeyStore(id: keyStoreId)
        let blockchain = Blockchain.evm(.ethereum(.mainnet))
        var account = makeAccount(keyStoreId: keyStoreId, blockchain: blockchain)
        let accountId = try await service.insertAccount(account, keyStore: keyStore)
        account.id = accountId

        let token = makeToken(address: "0x0000000000000000000000000000000000000001")
        _ = try await service.insertToken(token, blockchain: blockchain)

        let balance = Balance(
            account: account,
            amount: 100,
            token: token,
            usdValue: 12.5
        )

        let balanceId = try await service.saveBalance(balance)

        #expect(try await service.fetchBalances(accountId: accountId).count == 1)
        #expect(try await service.fetchBalances(accountId: accountId).first?.id == balanceId)

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
        // Prices belong to the price writer; a balance save only updates descriptive fields.
        try await service.updateTokenPrices([updatedToken])

        let fetched = try #require(try await service.fetchBalances(accountId: accountId).first)
        #expect(fetched.id == balanceId)
        #expect(fetched.amount == 250)
        #expect(fetched.usdValue == 25)
        #expect(fetched.token.name == "Updated Token")
        #expect(try await service.fetchTokens(account: account).contains {
            $0.address == token.address
        })
    }

    /// A multi-balance batch, including a brand-new token and a duplicate token
    /// address appearing twice in the same batch, is upserted in one call — and
    /// every returned identifier is the permanent one the row kept.
    @Test
    func balancePagesPreserveGlobalOrderAndHiddenTotals() async throws {
        let service = try makeDatabaseService()
        let keyStoreId = try await service.insertKeyStore(makeKeyStore())
        let keyStore = makeKeyStore(id: keyStoreId)
        var account = makeAccount(keyStoreId: keyStoreId, blockchain: .evm(.ethereum(.mainnet)))
        account.id = try await service.insertAccount(account, keyStore: keyStore)
        var lower = makeToken(address: "0x0000000000000000000000000000000000000001", usdPrice: 3)
        var higher = makeToken(address: "0x0000000000000000000000000000000000000002", usdPrice: 2)
        let hidden = makeToken(address: "0x0000000000000000000000000000000000000003", usdPrice: 100)
        lower.isWhitelisted = true
        higher.isWhitelisted = true
        try await service.saveBalances([
            Balance(account: account, amount: 2, token: lower, usdValue: nil),
            Balance(account: account, amount: 5, token: higher, usdValue: nil),
            Balance(account: account, amount: 1, token: hidden, usdValue: nil)
        ])

        let savedAccount = account
        let index = try await service.modelContainer.readSnapshot { reader in
            try await reader.balanceListIndex(
                for: savedAccount,
                sort: [BalanceListSort(field: .value, ascending: false)],
                separatesHidden: true
            )
        }

        let first = try await service.fetchBalancePage(for: account, orderedIds: index.visible, offset: 0, limit: 1)
        let second = try await service.fetchBalancePage(for: account, orderedIds: index.visible, offset: 1, limit: 1)
        let hiddenPage = try await service.fetchBalancePage(for: account, orderedIds: index.hidden, offset: 0, limit: 1)

        #expect(first.rows.map(\.token.address) == [higher.address])
        #expect(first.hasMore)
        #expect(second.rows.map(\.token.address) == [lower.address])
        #expect(!second.hasMore)
        #expect(hiddenPage.rows.map(\.token.address) == [hidden.address])
        #expect(index.totalUSDValue == 16)
    }

    @Test
    func savingABatchOfBalancesUpsertsEveryTokenInOneCall() async throws {
        let service = try makeDatabaseService()
        let keyStoreId = try await service.insertKeyStore(makeKeyStore())
        let keyStore = makeKeyStore(id: keyStoreId)
        let blockchain = Blockchain.evm(.ethereum(.mainnet))
        var account = makeAccount(keyStoreId: keyStoreId, blockchain: blockchain)
        let accountId = try await service.insertAccount(account, keyStore: keyStore)
        account.id = accountId

        let firstToken = makeToken(address: "0x0000000000000000000000000000000000000002")
        let duplicateAddress = "0x0000000000000000000000000000000000000003"
        let secondToken = makeToken(address: duplicateAddress, name: "Second Token")
        let secondTokenUpdated = makeToken(address: duplicateAddress, name: "Second Token Updated")

        let savedIds = try await service.saveBalances([
            Balance(account: account, amount: 5, token: firstToken, usdValue: 1),
            Balance(account: account, amount: 7, token: secondToken, usdValue: 2),
            Balance(account: account, amount: 9, token: secondTokenUpdated, usdValue: 3)
        ])

        let allBalances = try await service.fetchBalances(accountId: accountId)
        #expect(allBalances.count == 2)
        #expect(allBalances.contains { $0.token.address == firstToken.address && $0.amount == 5 })
        // Temporary identifiers — read before the context commits — would not
        // match the ones a later fetch reports.
        #expect(Set(savedIds) == Set(allBalances.compactMap(\.id)))

        let secondTokenBalances = allBalances.filter { $0.token.address == duplicateAddress }
        #expect(secondTokenBalances.count == 1)
        #expect(secondTokenBalances.first?.amount == 9)
    }

    @Test
    func updateBalancesUpdatesExistingBalancesAndInsertsNewTokens() async throws {
        let service = try makeDatabaseService()
        let keyStoreId = try await service.insertKeyStore(makeKeyStore())
        let keyStore = makeKeyStore(id: keyStoreId)
        let blockchain = Blockchain.evm(.ethereum(.mainnet))
        var account = makeAccount(keyStoreId: keyStoreId, blockchain: blockchain)
        let accountId = try await service.insertAccount(account, keyStore: keyStore)
        account.id = accountId

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

        let balances = try await service.fetchBalances(accountId: accountId)
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
        let keyStoreId = try await service.insertKeyStore(makeKeyStore())
        let keyStore = makeKeyStore(id: keyStoreId)
        let blockchain = Blockchain.evm(.ethereum(.mainnet))
        var account = makeAccount(keyStoreId: keyStoreId, blockchain: blockchain)
        let accountId = try await service.insertAccount(account, keyStore: keyStore)
        account.id = accountId

        let token = makeToken(address: "0x0000000000000000000000000000000000000001")
        _ = try await service.insertToken(token, blockchain: blockchain)

        let balance = Balance(
            account: account,
            amount: 100,
            token: token,
            usdValue: 12.5
        )

        _ = try await service.saveBalance(balance)
        #expect(try await service.fetchBalances(accountId: accountId).count == 1)

        try await service.deleteAllAccounts()

        #expect(try await service.fetchAccounts(keyStoreId: keyStoreId).isEmpty)
        #expect(try await service.fetchKeyStore(id: keyStoreId) != nil)
        #expect(try await service.fetchAccount(id: accountId) == nil)
        #expect(try await service.fetchBalances(accountId: accountId).isEmpty)
    }

    @Test
    func missingAndInvalidRecordsThrowExpectedErrors() async throws {
        let service = try makeDatabaseService()
        let missingId = try await service.insertKeyStore(makeKeyStore())
        let missingAccountId = try await service.insertKeyStore(makeKeyStore(name: "Other"))
        try await service.deleteKeyStore(id: missingAccountId)

        await #expect(throws: ReefrError.notFound) {
            try await service.renameKeyStore(id: missingAccountId, name: "Missing")
        }

        let account = makeAccount(
            keyStoreId: missingId,
            blockchain: .evm(.ethereum(.mainnet))
        )

        let deletedKeyStoreId = try await service.insertKeyStore(makeKeyStore(name: "Unrelated"))
        try await service.deleteKeyStore(id: deletedKeyStoreId)

        await #expect(throws: ReefrError.notFound) {
            try await service.insertAccount(account, keyStore: makeKeyStore(id: deletedKeyStoreId))
        }

        await #expect(throws: ReefrError.invalidData) {
            try await service.fetchTokens(account: account)
        }
    }
}

extension DatabaseServiceTests {
    func makeDatabaseService() throws -> DatabaseService {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: AccountModel.self,
            ApprovalModel.self,
            ApprovalScanModel.self,
            BalanceModel.self,
            BlockchainModel.self,
            KeyStoreModel.self,
            TokenModel.self,
            SavedAddressModel.self,
            StakingModel.self,
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
            mnemonicWordlist: .english,
            sealedEntropy: Data(repeating: 1, count: 16),
            transport: nil,
            vendor: nil
        )
    }

    func makeAccount(
        keyStoreId: PersistentIdentifier,
        blockchain: Blockchain,
        name: String = "Test Account"
    ) -> ReefrWallet.Account {
        Account(
            address: "0x0000000000000000000000000000000000000001",
            blockchain: blockchain,
            derivationPath: try? DerivationPath(string: "m/44'/60'/0'/0/0"),
            keyStoreId: keyStoreId,
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

private extension DatabaseService {
    func assignTestStakingToken(_ tokenId: PersistentIdentifier, accountId: PersistentIdentifier) throws {
        let stakingPredicate = #Predicate<StakingModel> { $0.account.persistentModelID == accountId }
        let staking = try #require(modelContext.fetch(FetchDescriptor(predicate: stakingPredicate)).first)
        let predicate = #Predicate<TokenModel> { $0.persistentModelID == tokenId }
        staking.token = try #require(modelContext.fetch(FetchDescriptor(predicate: predicate)).first)
        try modelContext.save()
    }
} // swiftlint:disable:this file_length
