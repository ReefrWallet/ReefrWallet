// A recipient-side outcome is stored apart from the sender's entry and outlives it being re-imported.

import Foundation
import SwiftData
import Testing
import WalletKit
@testable import ReefrWallet

struct TonDeliveryPersistenceTests {
    private let reference = TonDeliveryReference(outMessageHash: "hash")

    private func makeSend(age: TimeInterval = 60) throws -> BlockchainTransaction {
        BlockchainTransaction(
            identifier: "send",
            timestamp: Date.now.addingTimeInterval(-age),
            status: .confirmed,
            rawPayload: try reference.encoded()
        )
    }

    private func makeAccount(_ databaseService: DatabaseService) async throws -> ReefrWallet.Account {
        let keyStore = try await makeLocalKeyStore(databaseService: databaseService)
        let service = AccountService(databaseService: databaseService)
        return try await service.makeAccount(.ton(.testnet), keyStore: keyStore)
    }

    @Test func aBounceFoundLongAfterTheSendSurvivesTheSendersHistoryBeingImportedAgain() async throws {
        let databaseService = try makeDatabaseService()
        let account = try await makeAccount(databaseService)
        let accountId = try #require(account.id)
        let send = try makeSend(age: 3 * 24 * 3600)
        try await databaseService.saveTransactions([send], for: account)

        // Open however old it is.
        let open = try await databaseService.fetchUndecidedDeliveries(accountId: accountId)
        #expect(open.count == 1)

        try await databaseService.recordDelivery(stableId: try #require(open.first).stableId, outcome: .failed)

        // The sender's page is replayed: plain `confirmed` with a payload that knows no outcome.
        try await databaseService.saveTransactions([send], for: account)

        let stored = try #require(try await databaseService.fetchTransactions(accountId: accountId).first)
        #expect(stored.status == .failed)
        let kept: TonDeliveryReference = try #require(stored.rawPayload).decoded()
        #expect(kept.outcome == .failed)
        #expect(try await databaseService.fetchUndecidedDeliveries(accountId: accountId).isEmpty)
    }

    @Test func aDeliveredSendIsNotCheckedAgain() async throws {
        let databaseService = try makeDatabaseService()
        let account = try await makeAccount(databaseService)
        let accountId = try #require(account.id)
        try await databaseService.saveTransactions([try makeSend()], for: account)

        let open = try await databaseService.fetchUndecidedDeliveries(accountId: accountId)
        try await databaseService.recordDelivery(stableId: try #require(open.first).stableId, outcome: .delivered)
        try await databaseService.saveTransactions([try makeSend()], for: account)

        let stored = try #require(try await databaseService.fetchTransactions(accountId: accountId).first)
        #expect(stored.status == .confirmed)
        #expect(try await databaseService.fetchUndecidedDeliveries(accountId: accountId).isEmpty)
    }

    @Test func successivePassesCoverEveryOpenSend() {
        let open = Array(0 ..< 25)
        var seen = Set<Int>()

        for pass in 0 ..< 3 {
            seen.formUnion(TonSendService.rotating(open, from: pass * 10, count: 10))
        }

        #expect(seen == Set(open))
        #expect(TonSendService.rotating([Int](), from: 4, count: 10).isEmpty)
        #expect(TonSendService.rotating([1, 2], from: 5, count: 10) == [2, 1])
    }

    @Test func theNewestSendsAreCheckedOnEveryPass() {
        let open = Array(0 ..< 58)
        var seen = Set<Int>()

        for pass in 0 ..< 9 {
            let batch = TonSendService.deliveryBatch(open, offset: pass * 7)
            #expect(batch.count == 10)
            #expect(Array(batch.prefix(3)) == [0, 1, 2])
            seen.formUnion(batch)
        }

        #expect(seen == Set(open))
    }

    @Test func aFailingLookupDoesNotStopTheOtherSends() async {
        struct Offline: Error {}

        let sends = ["a", "b", "c"].map { (stableId: $0, reference: TonDeliveryReference(outMessageHash: $0)) }
        var recorded: [String: TonDeliveryReference.Outcome] = [:]
        var failures = 0

        await TonSendService.settle(
            sends,
            lookup: { reference in
                switch reference.outMessageHash {
                case "a": throw Offline()
                case "b": return .delivered
                default: return .bounced
                }
            },
            record: { recorded[$0] = $1 },
            onFailure: { _ in failures += 1 }
        )

        #expect(recorded == ["b": .delivered, "c": .failed])
        #expect(failures == 1)
    }

    @Test func theJettonScanStoresItsProgressWithoutTouchingTheWalletsOwnSyncState() async throws {
        let databaseService = try makeDatabaseService()
        let account = try await makeAccount(databaseService)
        let accountId = try #require(account.id)

        var own = WalletTransactionSyncState(accountId: accountId)
        own.currentHead = 42
        own.ascendingCursor = Data([1])
        try await databaseService.saveTransactionSyncState(own)

        let backfill = try TonJettonScanner.Backfill(cursor: "c50", endLt: 9).encoded()
        try await databaseService.saveJettonSync([try makeSend()], for: account, backfill: backfill, forward: nil)

        let stored = try await databaseService.fetchJettonSyncProgress(accountId: accountId)
        #expect(stored.backfill == backfill)
        #expect(stored.forward == nil)

        // The wallet's own scan saves its state again: the Jetton progress is not overwritten.
        try await databaseService.saveTransactionSyncState(own)
        #expect(try await databaseService.fetchJettonSyncProgress(accountId: accountId).backfill == backfill)

        let state = try await databaseService.transactionSyncState(accountId: accountId)
        #expect(state.currentHead == 42)
        #expect(state.ascendingCursor == Data([1]))
    }

    /// The Jetton payment of one request, in each order its sources can arrive: the send placeholder, the owner
    /// wallet's request entry (no Gram payment for a Jetton request) and the Jetton history's effect.
    @Test(arguments: [[0, 1, 2], [1, 2], [2, 1], [0, 2, 1]])
    func aJettonSendIsOnePaymentHoweverItsSourcesArrive(order: [Int]) async throws {
        let databaseService = try makeDatabaseService()
        let account = try await makeAccount(databaseService)
        let owner = try TonAddress(string: account.address)
        let master = try TonAddress(workchain: 0, hash: Data(repeating: 2, count: 32), isBounceable: true)
        let receiver = try TonAddress(workchain: 0, hash: Data(repeating: 3, count: 32))

        let placeholder = BlockchainTransaction(
            identifier: "req",
            sender: owner.string,
            status: .broadcast,
            effects: [
                BlockchainTransactionEffect(
                    index: 0,
                    kind: .tokenTransfer,
                    assetIdentifier: master.string,
                    amount: "10",
                    from: owner.string,
                    to: receiver.string,
                    rawPayload: Data("query:5|local".utf8)
                )
            ]
        )

        let request = BlockchainTransaction(
            identifier: "req",
            blockHeight: 7,
            sender: owner.string,
            status: .confirmed,
            effects: [],
            fee: "5000"
        )

        let action = TonJettonAction(
            actionId: "abcdef",
            amount: 10,
            lt: 9,
            master: master,
            queryId: "5",
            receiver: receiver,
            requestHash: "req",
            sender: owner,
            traceId: "t"
        ).transaction(owner: owner)

        for index in order {
            try await databaseService.saveTransactions([[placeholder, request, action][index]], for: account)
        }

        let stored = try await databaseService.fetchTransactions(accountId: #require(account.id))
        let row = try #require(stored.first)
        #expect(stored.count == 1)
        #expect(row.status == .confirmed)
        #expect(row.effects.map(\.kind) == [.tokenTransfer])
        #expect(row.effects.first?.amount == "10")
        #expect(row.fee == "5000")
    }

    @Test func effectsWhoseActionIdsShareAPrefixStayApart() async throws {
        let databaseService = try makeDatabaseService()
        let account = try await makeAccount(databaseService)
        let owner = try TonAddress(string: account.address)
        let master = try TonAddress(workchain: 0, hash: Data(repeating: 2, count: 32), isBounceable: true)
        let receiver = try TonAddress(workchain: 0, hash: Data(repeating: 3, count: 32))

        let entries = ["0123456789abcdef0001", "0123456789abcdef0002"].map {
            TonJettonAction(
                actionId: $0, amount: 1, lt: 9, master: master, queryId: "5", receiver: receiver,
                requestHash: "req", sender: owner, traceId: "t"
            ).transaction(owner: owner)
        }

        try await databaseService.saveTransactions(entries, for: account)
        let stored = try await databaseService.fetchTransactions(accountId: #require(account.id))
        #expect(stored.flatMap(\.effects).count == 2)
    }

    @Test func repairingStableIdsKeepsEffectsThatDifferOnlyByKey() async throws {
        let databaseService = try makeDatabaseService()
        let account = try await makeAccount(databaseService)
        let owner = try TonAddress(string: account.address)
        let master = try TonAddress(workchain: 0, hash: Data(repeating: 2, count: 32), isBounceable: true)
        let receiver = try TonAddress(workchain: 0, hash: Data(repeating: 3, count: 32))

        let entries = ["0123456789abcdef0001", "0123456789abcdef0002"].map {
            TonJettonAction(
                actionId: $0, amount: 1, lt: 9, master: master, receiver: receiver,
                requestHash: "req", sender: owner, traceId: "t"
            ).transaction(owner: owner)
        }

        try await databaseService.saveTransactions(entries, for: account)

        // Age the row to the old id form, with effect ids built on it.
        let context = ModelContext(databaseService.modelContainer)
        let model = try #require(context.fetch(FetchDescriptor<WalletTransactionModel>()).first)
        let current = model.stableId
        model.stableId = "old"

        for effect in model.effects {
            effect.stableId = "old" + effect.stableId.dropFirst(current.count)
        }

        try context.save()

        try await databaseService.normalizeTransactionStableIds()
        let stored = try await databaseService.fetchTransactions(accountId: #require(account.id))
        #expect(stored.flatMap(\.effects).count == 2)
        #expect(Set(stored.flatMap(\.effects).map(\.stableId)).count == 2)
        #expect(stored.flatMap(\.effects).allSatisfy { $0.stableId.hasPrefix(current + "|") })
    }

    private func jettonSend(status: BlockchainTransactionStatus = .unconfirmed) throws -> BlockchainTransaction {
        let reference = TonDeliveryReference(outMessageHash: "out", isJettonRequest: true, requestHash: "req")
        return BlockchainTransaction(
            identifier: "req",
            timestamp: .now.addingTimeInterval(-60),
            status: status,
            rawPayload: try reference.encoded()
        )
    }

    private let transfer = TonJettonTransfer(
        amount: "10",
        master: "kMaster",
        queryId: 5,
        recipient: "r",
        senderWallet: "w"
    )

    @Test func theSendRecordsIntentSurvivesTheRequestEntryReplacingIt() async throws {
        let databaseService = try makeDatabaseService()
        let account = try await makeAccount(databaseService)
        let accountId = try #require(account.id)
        let pending = TonPendingSend(
            normalizedHash: "req", sender: "s", seqno: 1, signedMessage: Data([1]), validUntil: 2, jetton: transfer
        )

        let placeholder = BlockchainTransaction(
            identifier: "req",
            status: .broadcast,
            rawPayload: try JSONEncoder().encode(pending),
            effects: [transfer.placeholderEffect(sender: "s")]
        )

        try await databaseService.saveTransactions([placeholder], for: account)
        try await databaseService.saveTransactions([try jettonSend()], for: account)

        let open = try #require(try await databaseService.fetchUndecidedDeliveries(accountId: accountId).first)
        #expect(open.reference.jetton == transfer)
        #expect(open.reference.requestHash == "req")

        // Replaying the sender's history keeps it, and the row stays pending while the delivery is open.
        try await databaseService.saveTransactions([try jettonSend()], for: account)
        let again = try #require(try await databaseService.fetchUndecidedDeliveries(accountId: accountId).first)
        #expect(again.reference.jetton == transfer)
        let row = try #require(try await databaseService.fetchTransactions(accountId: accountId).first)
        #expect(row.status == .unconfirmed)
    }

    @Test func aDeliveredJettonRequestBecomesConfirmedAndStaysSoWhenReplayed() async throws {
        let databaseService = try makeDatabaseService()
        let account = try await makeAccount(databaseService)
        let accountId = try #require(account.id)
        try await databaseService.saveTransactions([try jettonSend()], for: account)

        let open = try #require(try await databaseService.fetchUndecidedDeliveries(accountId: accountId).first)
        try await databaseService.recordDelivery(stableId: open.stableId, outcome: .delivered)
        try await databaseService.saveTransactions([try jettonSend()], for: account)

        let row = try #require(try await databaseService.fetchTransactions(accountId: accountId).first)
        #expect(row.status == .confirmed)
        #expect(try await databaseService.fetchUndecidedDeliveries(accountId: accountId).isEmpty)
    }

    @Test func aRestoredRequestRebuildsItsIntentFromItsOneTokenEffect() async throws {
        let databaseService = try makeDatabaseService()
        let account = try await makeAccount(databaseService)
        let accountId = try #require(account.id)
        let send = try jettonSend()

        let restored = BlockchainTransaction(
            identifier: send.identifier,
            status: .unconfirmed,
            rawPayload: send.rawPayload,
            effects: [transfer.placeholderEffect(sender: "s")]
        )

        try await databaseService.saveTransactions([restored], for: account)
        let open = try #require(try await databaseService.fetchUndecidedDeliveries(accountId: accountId).first)
        #expect(open.reference.jetton?.queryId == 5)
        #expect(open.reference.jetton?.amount == "10")
        #expect(open.reference.jetton?.senderWallet == "")
    }

    @Test func aRestoredRefusedSendWithNoTokenEffectIsStillCheckedByItsFirstHop() async throws {
        let databaseService = try makeDatabaseService()
        let account = try await makeAccount(databaseService)
        let accountId = try #require(account.id)
        try await databaseService.saveTransactions([try jettonSend()], for: account)

        // No token effect to rebuild the intent from, yet the row is open and carries the first-hop hash.
        let open = try #require(try await databaseService.fetchUndecidedDeliveries(accountId: accountId).first)
        #expect(open.reference.jetton == nil)
        #expect(open.reference.outMessageHash == "out")
    }
}
