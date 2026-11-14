// A recipient-side outcome is stored apart from the sender's entry and outlives it being re-imported.

import Foundation
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

    @Test func aFailingLookupDoesNotStopTheOtherSends() async {
        struct Offline: Error {}

        let sends = ["a", "b", "c"].map { (stableId: $0, reference: TonDeliveryReference(outMessageHash: $0)) }
        var recorded: [String: TonDeliveryReference.Outcome] = [:]
        var failures = 0

        await TonSendService.settle(
            sends,
            lookup: { hash in
                switch hash {
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
}
