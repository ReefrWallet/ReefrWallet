// The Blockscout backfill pages ERC-20 transfers alongside transactions, so a token
// received before the first sync (a transaction the account didn't send) is discovered.

import Foundation
@testable import ReefrWallet
import Testing
import WalletKit

struct BlockscoutBackfillTests {
    private static let owner = BlockscoutFixtures.owner
    private static let usdc = BlockscoutFixtures.usdc
    private static let sepolia = Blockchain.evm(.ethereum(.sepolia))

    private func makeSource(_ stub: BlockscoutStubURLProtocol.Stub) -> BlockscoutTransactionHistorySource {
        BlockscoutTransactionHistorySource(
            apiBaseURLs: [11_155_111: URL(string: "https://\(stub.host)/api/v2")!],
            sessionConfiguration: stub.configuration
        )
    }

    private func makeAccount() async throws -> ReefrWallet.Account {
        let databaseService = try makeDatabaseService()
        let keyStore = try await makeWatchOnlyKeyStore(databaseService: databaseService, name: "Blockscout Backfill")
        var account = ReefrWallet.Account(
            address: Self.owner,
            blockchain: Self.sepolia,
            derivationPath: nil,
            keyStoreId: try #require(keyStore.id),
            name: "Blockscout"
        )

        account.id = try await databaseService.insertAccount(account, keyStore: keyStore)
        return account
    }

    private func backfill(
        _ source: BlockscoutTransactionHistorySource,
        account: ReefrWallet.Account,
        cursor: Data? = nil
    ) async throws -> BlockchainTransactionPage {
        try await source.transactionHistory(
            account: account,
            request: BlockchainTransactionHistoryRequest(
                cursor: cursor,
                direction: .descending,
                lowerBound: 0,
                upperBound: nil
            )
        )
    }

    @Test func aTokenReceivedInATransactionTheAccountDidNotSendIsDiscovered() async throws {
        let stub = BlockscoutStubURLProtocol.make(routes: [
            "\(Self.owner)/transactions": BlockscoutFixtures.list([BlockscoutFixtures.transaction(hash: "0xsent", block: 200)]),
            "\(Self.owner)/token-transfers": BlockscoutFixtures.list([BlockscoutFixtures.transfer(hash: "0xreceived", block: 100, value: "20000000")])
        ])

        let page = try await backfill(makeSource(stub), account: try await makeAccount())

        let received = try #require(page.transactions.first { $0.identifier == "0xreceived" })
        let effect = try #require(received.effects.first { $0.kind == .tokenTransfer })
        #expect(effect.assetIdentifier == Self.usdc)
        #expect(effect.amount == "20000000")
        #expect(page.transactions.contains { $0.identifier == "0xsent" })
        #expect(page.reachedBoundary)
        #expect(page.nextCursor == nil)
        #expect(page.head == 200)
    }

    @Test func bothListsArePagedUntilEachIsExhausted() async throws {
        let next = #"{"block_number":150,"index":0,"items_count":50}"#
        let stub = BlockscoutStubURLProtocol.make(routes: [
            "\(Self.owner)/transactions": BlockscoutFixtures.list([BlockscoutFixtures.transaction(hash: "0xnew", block: 200)], next: next),
            "\(Self.owner)/transactions?block_number=150&index=0&items_count=50":
                BlockscoutFixtures.list([BlockscoutFixtures.transaction(hash: "0xold", block: 120)]),
            "\(Self.owner)/token-transfers": BlockscoutFixtures.list([BlockscoutFixtures.transfer(hash: "0xtoken", block: 190, value: "1")])
        ])

        let source = makeSource(stub)
        let account = try await makeAccount()

        let first = try await backfill(source, account: account)
        #expect(!first.reachedBoundary)
        let cursor = try #require(first.nextCursor)

        let second = try await backfill(source, account: account, cursor: cursor)
        #expect(second.reachedBoundary)
        #expect(second.transactions.map(\.identifier) == ["0xold"])

        // The finished token list isn't requested again.
        #expect(stub.requests(path: "\(Self.owner)/token-transfers").count == 1)
        #expect(stub.requests(path: "\(Self.owner)/transactions").count == 2)
    }

    @Test func aCursorSavedByAnOlderVersionStillResumesTheTransactionList() async throws {
        let legacy = #"{"block_number":150,"index":0,"items_count":50}"#
        let stub = BlockscoutStubURLProtocol.make(routes: [
            "\(Self.owner)/transactions?block_number=150&index=0&items_count=50":
                BlockscoutFixtures.list([BlockscoutFixtures.transaction(hash: "0xold", block: 120)]),
            "\(Self.owner)/token-transfers": BlockscoutFixtures.list([BlockscoutFixtures.transfer(hash: "0xtoken", block: 190, value: "1")])
        ])

        let page = try await backfill(
            makeSource(stub),
            account: try await makeAccount(),
            cursor: Data(legacy.utf8)
        )

        // Transactions resume where they stopped; token transfers start from the newest.
        #expect(Set(page.transactions.map(\.identifier)) == ["0xold", "0xtoken"])
        #expect(page.reachedBoundary)
    }

    @Test func aPendingTransactionDoesNotFailThePage() async throws {
        let stub = BlockscoutStubURLProtocol.make(routes: [
            "\(Self.owner)/transactions": BlockscoutFixtures.list([
                BlockscoutFixtures.pending(hash: "0xpending"),
                BlockscoutFixtures.transaction(hash: "0xmined", block: 200)
            ]),
            "\(Self.owner)/token-transfers": BlockscoutFixtures.list([])
        ])

        let page = try await backfill(makeSource(stub), account: try await makeAccount())

        #expect(page.transactions.map(\.identifier) == ["0xmined"])
        #expect(page.reachedBoundary)
    }

    @Test func aConfirmedItemThatDoesNotDecodeFailsThePage() async throws {
        let broken = #"{"block_number":150,"hash":"0xbroken"}"#
        let stub = BlockscoutStubURLProtocol.make(routes: [
            "\(Self.owner)/transactions": BlockscoutFixtures.list([broken]),
            "\(Self.owner)/token-transfers": BlockscoutFixtures.list([])
        ])

        await #expect(throws: (any Error).self) {
            _ = try await backfill(makeSource(stub), account: try await makeAccount())
        }
    }

    @Test func aForwardScanFollowsTheCursorPastAnAllPendingPage() async throws {
        let next = #"{"block_number":150,"index":0,"items_count":50}"#
        let stub = BlockscoutStubURLProtocol.make(routes: [
            "\(Self.owner)/transactions": BlockscoutFixtures.list([BlockscoutFixtures.pending(hash: "0xp")], next: next),
            "\(Self.owner)/transactions?block_number=150&index=0&items_count=50":
                BlockscoutFixtures.list([BlockscoutFixtures.transaction(hash: "0xmined", block: 120)]),
            "\(Self.owner)/token-transfers": BlockscoutFixtures.list([])
        ])

        let page = try await makeSource(stub).transactionHistory(
            account: try await makeAccount(),
            request: BlockchainTransactionHistoryRequest(
                cursor: nil,
                direction: .ascending,
                lowerBound: 100,
                upperBound: nil
            )
        )

        #expect(page.transactions.map(\.identifier) == ["0xmined"])
    }
}
