// Effects-only records never overwrite a stored transaction, and accounts whose history backfill
// finished before it included ERC-20 transfers get one resumable pass that keeps forward progress.

import Foundation
@testable import ReefrWallet
import Testing
import WalletKit

struct TokenTransferBackfillTests {
    private let owner = BlockscoutFixtures.owner
    private let usdc = BlockscoutFixtures.usdc
    private let sepolia = Blockchain.evm(.ethereum(.sepolia))

    private func makeAccount(_ databaseService: DatabaseService) async throws -> ReefrWallet.Account {
        let keyStore = try await makeWatchOnlyKeyStore(databaseService: databaseService, name: "Token Backfill")
        var account = ReefrWallet.Account(
            address: owner,
            blockchain: sepolia,
            derivationPath: nil,
            keyStoreId: try #require(keyStore.id),
            name: "Token Backfill"
        )

        account.id = try await databaseService.insertAccount(account, keyStore: keyStore)
        return account
    }

    private func makeService(
        _ stub: BlockscoutStubURLProtocol.Stub,
        _ databaseService: DatabaseService
    ) -> TransactionSyncService {
        TransactionSyncService(
            clientProvider: BlockchainClientProvider(),
            databaseService: databaseService,
            transactionHistorySources: [
                BlockscoutTransactionHistorySource(
                    apiBaseURLs: [11_155_111: URL(string: "https://\(stub.host)/api/v2")!],
                    sessionConfiguration: stub.configuration
                )
            ]
        )
    }

    private func full(_ hash: String) -> BlockchainTransaction {
        BlockchainTransaction(
            identifier: hash,
            blockHeight: 100,
            timestamp: Date(timeIntervalSince1970: 1_000),
            sender: owner,
            recipient: "0xcontract",
            status: .confirmed,
            rawPayload: Data("full".utf8),
            counterpartyName: "Router",
            fee: "21",
            method: "Approve"
        )
    }

    private func effectsOnly(_ hash: String, index: UInt64) -> BlockchainTransaction {
        BlockchainTransaction(
            identifier: hash,
            blockHeight: 100,
            sender: "0xsomeone",
            recipient: owner,
            status: .confirmed,
            effects: [
                BlockchainTransactionEffect(
                    index: index,
                    kind: .tokenTransfer,
                    assetIdentifier: usdc,
                    amount: "7",
                    from: "0xsomeone",
                    to: owner
                )
            ],
            counterpartyName: "USDC",
            method: "Transfer",
            isEffectsOnly: true
        )
    }

    @Test func effectsOnlyAfterTheFullTransactionKeepsItsFieldsAndAddsTheEffect() async throws {
        let databaseService = try makeDatabaseService()
        let account = try await makeAccount(databaseService)

        try await databaseService.saveTransactions([full("0xa")], for: account)
        try await databaseService.saveTransactions([effectsOnly("0xa", index: 3)], for: account)

        let accountId = try #require(account.id)
        let transactions = try await databaseService.fetchTransactions(accountId: accountId)
        let stored = try #require(transactions.first)

        #expect(stored.sender == owner)
        #expect(stored.recipient == "0xcontract")
        #expect(stored.rawPayload == Data("full".utf8))
        #expect(stored.method == "Approve")
        #expect(stored.counterpartyName == "Router")
        #expect(stored.effects.map(\.kind) == [.tokenTransfer])
    }

    @Test func theFullTransactionAfterEffectsOnlyReplacesTheirPlaceholderFields() async throws {
        let databaseService = try makeDatabaseService()
        let account = try await makeAccount(databaseService)

        try await databaseService.saveTransactions([effectsOnly("0xa", index: 3)], for: account)
        try await databaseService.saveTransactions([full("0xa")], for: account)

        let accountId = try #require(account.id)
        let transactions = try await databaseService.fetchTransactions(accountId: accountId)
        let stored = try #require(transactions.first)

        #expect(stored.sender == owner)
        #expect(stored.recipient == "0xcontract")
        #expect(stored.rawPayload == Data("full".utf8))
        #expect(stored.method == "Approve")
        #expect(stored.effects.count == 1)
    }

    @Test func onlyContractFailuresOfTokenMetadataAreSkipped() {
        #expect(TransactionSyncService.isPermanentTokenFailure(
            BlockchainClientError.decodingFailed(reason: "string return data too short")
        ))
        #expect(TransactionSyncService.isPermanentTokenFailure(
            BlockchainClientError.rpcError(code: 3, message: "execution reverted")
        ))
        #expect(!TransactionSyncService.isPermanentTokenFailure(
            BlockchainClientError.transportError(reason: "timed out")
        ))
        #expect(!TransactionSyncService.isPermanentTokenFailure(
            BlockchainClientError.quotaExceeded(code: 429, message: "limit", retryAfter: nil)
        ))
        #expect(!TransactionSyncService.isPermanentTokenFailure(
            BlockchainClientError.rpcError(code: -32000, message: "header not found")
        ))
    }

    @Test func anAccountThatCompletedAnOlderBackfillGetsOneResumablePassKeepingForwardProgress() async throws {
        let databaseService = try makeDatabaseService()
        let account = try await makeAccount(databaseService)
        let accountId = try #require(account.id)

        // State left by the old, transactions-only backfill, with forward progress.
        var state = WalletTransactionSyncState(accountId: accountId)
        state.backfillComplete = true
        state.currentHead = 500
        state.ascendingCursor = Data("forward".utf8)
        state.initialBackfillHead = 400
        try await databaseService.saveTransactionSyncState(state)
        try await databaseService.saveTransactions([full("0xsent")], for: account)

        let next = #"{"block_number":90,"index":0,"items_count":50}"#
        let first = BlockscoutStubURLProtocol.make(routes: [
            "\(owner)/token-transfers": BlockscoutFixtures.list(
                [BlockscoutFixtures.transfer(hash: "0xnewer", block: 300, value: "5")],
                next: next
            )
        ])

        let service = makeService(first, databaseService)

        let client = try BlockchainClientProvider().makeClient(blockchain: sepolia, rpcURL: nil, backend: nil)

        // The second page fails: the pass stops, its progress is saved, forward state is untouched.
        await #expect(throws: (any Error).self) {
            _ = try await service.backfillTokenTransfers(account: account, client: client)
        }

        var saved = try await databaseService.transactionSyncState(accountId: accountId)
        #expect(saved.tokenBackfillVersion == 0)
        #expect(saved.tokenBackfillCursor != nil)
        #expect(saved.currentHead == 500)
        #expect(saved.ascendingCursor == Data("forward".utf8))

        // Resumed with the older page: it finishes and leaves the stored transaction alone.
        let second = BlockscoutStubURLProtocol.make(routes: [
            "\(owner)/token-transfers?block_number=90&index=0&items_count=50": BlockscoutFixtures.list(
                [BlockscoutFixtures.transfer(hash: "0xolder", block: 80, value: "9")]
            )
        ])

        let resumed = makeService(second, databaseService)

        let finished = try await resumed.backfillTokenTransfers(account: account, client: client)
        #expect(finished)

        saved = try await databaseService.transactionSyncState(accountId: accountId)
        #expect(saved.tokenBackfillVersion == 1)
        #expect(saved.tokenBackfillCursor == nil)
        #expect(saved.currentHead == 500)
        #expect(saved.ascendingCursor == Data("forward".utf8))

        let identifiers = try await databaseService.fetchTransactions(accountId: accountId).map(\.identifier)
        #expect(Set(identifiers) == ["0xsent", "0xnewer", "0xolder"])
        #expect(try await databaseService.fetchToken(tokenAddress: usdc, blockchain: sepolia) != nil)

        // Done: a further call does nothing.
        #expect(try await resumed.backfillTokenTransfers(account: account, client: client) == false)
    }
}
