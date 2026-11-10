// What becomes of a Sui staking transaction: every outcome, what is recorded and when, one at a time,
// and recovery after the app reopens.

import Foundation
import SwiftData
import Testing
import WalletKit
@testable import ReefrWallet

private struct Harness {
    let account: ReefrWallet.Account
    let accountId: PersistentIdentifier
    let changes = ChangeCounter()
    let database: DatabaseService
    let loader: SuiStakingPositionLoader
    let service: SuiStakingService
    let source = FakeSuiStakingSource()

    init() async throws {
        database = try makeDatabaseService()
        account = try await makeSuiStakingAccount(database)
        accountId = try idOf(account)

        let changes = changes
        let source = source
        let clock = SteppingClock()
        source.use(database)
        loader = SuiStakingPositionLoader(
            databaseService: database,
            source: source,
            now: { clock.now() },
            onResolved: { await changes.record($0) }
        )

        service = SuiStakingService(
            positionLoader: loader,
            source: source,
            confirmationPollInterval: .milliseconds(1),
            confirmationPollLimit: 3,
            now: { clock.now() },
            onChanged: { await changes.record($0) }
        )
    }

    /// Prepares `prepared`'s action through the service, so the position row exists.
    func prepare(_ prepared: SuiPreparedStaking) async throws -> SuiPreparedStaking {
        source.answerPrepare(with: .success(prepared))
        return try await service.prepare(prepared.action, account: account)
    }

    func pending() async throws -> [SuiPendingSubmission] {
        try await loader.pendingSubmissions(accountId: accountId)
    }
}

@Suite(.timeLimit(.minutes(1)))
struct SuiStakingServiceTests {
    // MARK: Recording

    @Test func anUnresolvedSubmissionIsRecordedBeforeSendingAndKept() async throws {
        let harness = try await Harness()
        let prepared = try await harness.prepare(try suiPrepared())

        let outcome = try await harness.service.submit(prepared, signature: Data([1]), account: harness.account)

        let digest = Base58.encode(prepared.digest)
        #expect(outcome == .submitted(digest: digest))
        #expect(try await harness.pending().map(\.digest) == [digest])
        #expect(harness.source.broadcasts == [true])
        #expect(harness.source.recorded == [digest])
    }

    @Test func aSecondTransactionIsRefusedWhileOneIsUnresolved() async throws {
        let harness = try await Harness()
        let first = try await harness.prepare(try suiPrepared())
        _ = try await harness.service.submit(first, signature: Data([1]), account: harness.account)

        await #expect(throws: SuiStakingServiceError.submissionUnresolved) {
            try await harness.service.prepare(first.action, account: harness.account)
        }

        let second = try suiPrepared(digestByte: 0xD2)
        await #expect(throws: SuiStakingServiceError.submissionUnresolved) {
            try await harness.service.submit(second, signature: Data([2]), account: harness.account)
        }

        #expect(harness.source.broadcasts == [true], "the refused one was never sent")
        #expect(try await harness.pending().count == 1)
    }

    @Test func twoSendsAtOnceCannotBothClaim() async throws {
        let harness = try await Harness()
        let first = try await harness.prepare(try suiPrepared())
        let second = try suiPrepared(digestByte: 0xD2)

        let service = harness.service
        let account = harness.account
        async let one = Self.attempt { try await service.submit(first, signature: Data([1]), account: account) }
        async let two = Self.attempt { try await service.submit(second, signature: Data([2]), account: account) }
        let results = await [one, two]

        #expect(results.filter { if case .success = $0 { true } else { false } }.count == 1)
        #expect(harness.source.broadcasts.count == 1)
        #expect(try await harness.pending().count == 1)
    }

    private static func attempt(
        _ body: @Sendable () async throws -> SuiStakingOutcome
    ) async -> Result<SuiStakingOutcome, Error> {
        do {
            return .success(try await body())
        } catch {
            return .failure(error)
        }
    }

    // MARK: Outcomes

    @Test func aFinalizedSuccessClearsTheRecordAndRefreshesThePosition() async throws {
        let harness = try await Harness()
        harness.source.answerResolve(with: [.unresolved(.stillValid), .succeeded])
        let prepared = try await harness.prepare(try suiPrepared())

        let outcome = try await harness.service.submit(prepared, signature: Data([1]), account: harness.account)

        #expect(outcome == .confirmed)
        #expect(try await harness.pending().isEmpty)
        #expect(await harness.changes.accounts == [harness.account.address])
    }

    @Test func aFinalizedFailureClearsTheRecordToo() async throws {
        let harness = try await Harness()
        harness.source.answerResolve(with: [.failed("MoveAbort")])
        let prepared = try await harness.prepare(try suiPrepared())

        let outcome = try await harness.service.submit(prepared, signature: Data([1]), account: harness.account)

        #expect(outcome == .failed)
        #expect(try await harness.pending().isEmpty)
    }

    @Test func aProvenNonExecutionClearsTheRecord() async throws {
        let harness = try await Harness()
        harness.source.answerResolve(with: [.notExecuted(.inputsUntouched)])
        let prepared = try await harness.prepare(try suiPrepared())

        let outcome = try await harness.service.submit(prepared, signature: Data([1]), account: harness.account)

        #expect(outcome == .notExecuted)
        #expect(try await harness.pending().isEmpty)
        #expect(harness.source.discarded == [Base58.encode(prepared.digest)], "its history placeholder goes too")
    }

    @Test func aRejectionOfTheTransactionItselfReleasesItAndSendsNothingElse() async throws {
        let harness = try await Harness()
        harness.source.answerBroadcast(with: .released)
        let prepared = try await harness.prepare(try suiPrepared())

        await #expect(throws: SuiStakingServiceError.rejected) {
            try await harness.service.submit(prepared, signature: Data([1]), account: harness.account)
        }

        #expect(try await harness.pending().isEmpty)
        #expect(harness.source.recorded.isEmpty)
    }

    @Test func aWrongNetworkReleasesItAndNothingWasSent() async throws {
        let harness = try await Harness()
        harness.source.answerBroadcast(with: .chainMismatch)
        let prepared = try await harness.prepare(try suiPrepared())

        await #expect(throws: SuiStakingServiceError.wrongNetwork) {
            try await harness.service.submit(prepared, signature: Data([1]), account: harness.account)
        }

        #expect(try await harness.pending().isEmpty)
        #expect(harness.source.recorded.isEmpty)
    }

    @Test func anAmbiguousBroadcastIsFollowedLikeASuccess() async throws {
        let harness = try await Harness()
        harness.source.answerBroadcast(with: .keepPending)
        let prepared = try await harness.prepare(try suiPrepared())

        let outcome = try await harness.service.submit(prepared, signature: Data([1]), account: harness.account)

        #expect(outcome == .submitted(digest: Base58.encode(prepared.digest)))
        #expect(harness.source.recorded.count == 1, "it may have landed, so history must watch for it")
        #expect(try await harness.pending().count == 1)
    }

    // MARK: Recovery

    @Test func anUnresolvedSubmissionIsResolvedAfterTheAppReopens() async throws {
        let harness = try await Harness()
        let prepared = try await harness.prepare(try suiPrepared())
        _ = try await harness.service.submit(prepared, signature: Data([1]), account: harness.account)
        #expect(try await harness.pending().count == 1)

        // A new process: new loader and source over the same store.
        let source = FakeSuiStakingSource()
        source.answerResolve(with: [.succeeded])
        let resolved = ChangeCounter()
        let reopened = SuiStakingPositionLoader(
            databaseService: harness.database,
            source: source,
            onResolved: { await resolved.record($0) }
        )

        await reopened.reconcilePending(harness.account, accountId: harness.accountId)

        #expect(try await reopened.pendingSubmissions(accountId: harness.accountId).isEmpty)
        #expect(await resolved.accounts == [harness.account.address])
    }

    @Test func aProvenNonExecutionAfterReopeningDiscardsThePlaceholderToo() async throws {
        let harness = try await Harness()
        let prepared = try await harness.prepare(try suiPrepared())
        _ = try await harness.service.submit(prepared, signature: Data([1]), account: harness.account)

        let source = FakeSuiStakingSource()
        source.use(harness.database)
        source.answerResolve(with: [.notExecuted(.inputSpentElsewhere(by: "Other"))])
        let reopened = SuiStakingPositionLoader(databaseService: harness.database, source: source, onResolved: { _ in })

        await reopened.reconcilePending(harness.account, accountId: harness.accountId)

        #expect(try await reopened.pendingSubmissions(accountId: harness.accountId).isEmpty)
        #expect(source.discarded == [Base58.encode(prepared.digest)])
    }

    @Test func aSucceededOrFailedSubmissionKeepsItsHistoryRow() async throws {
        let harness = try await Harness()
        harness.source.answerResolve(with: [.succeeded])
        let prepared = try await harness.prepare(try suiPrepared())

        _ = try await harness.service.submit(prepared, signature: Data([1]), account: harness.account)

        #expect(harness.source.discarded.isEmpty)
    }

    @Test func aFailedCleanupKeepsTheClaimSoTheNextCheckRetriesBoth() async throws {
        let harness = try await Harness()
        let prepared = try await harness.prepare(try suiPrepared())
        _ = try await harness.service.submit(prepared, signature: Data([1]), account: harness.account)
        let digest = Base58.encode(prepared.digest)

        let source = FakeSuiStakingSource()
        source.use(harness.database)
        source.answerResolve(with: [.notExecuted(.inputsUntouched)])
        source.failNextClears(1)
        let resolved = ChangeCounter()
        let reopened = SuiStakingPositionLoader(
            databaseService: harness.database, source: source, onResolved: { await resolved.record($0) }
        )

        await reopened.reconcilePending(harness.account, accountId: harness.accountId)

        #expect(try await reopened.pendingSubmissions(accountId: harness.accountId).map(\.digest) == [digest])
        #expect(source.discarded.isEmpty)
        #expect(await resolved.accounts.isEmpty, "nothing was resolved")

        await reopened.reconcilePending(harness.account, accountId: harness.accountId)

        #expect(try await reopened.pendingSubmissions(accountId: harness.accountId).isEmpty)
        #expect(source.discarded == [digest])
        #expect(await resolved.accounts == [harness.account.address])
    }

    @Test func aFailedCleanupWhileWaitingLeavesTheSubmissionPendingForARetry() async throws {
        let harness = try await Harness()
        harness.source.answerResolve(with: [.notExecuted(.inputsUntouched)])
        harness.source.failNextClears(1)
        let prepared = try await harness.prepare(try suiPrepared())

        let outcome = try await harness.service.submit(prepared, signature: Data([1]), account: harness.account)

        #expect(outcome == .notExecuted, "the retry within the same wait succeeded")
        #expect(try await harness.pending().isEmpty)
        #expect(harness.source.discarded == [Base58.encode(prepared.digest)])
    }

    @Test func aStillUnresolvedSubmissionStaysAfterReopening() async throws {
        let harness = try await Harness()
        let prepared = try await harness.prepare(try suiPrepared())
        _ = try await harness.service.submit(prepared, signature: Data([1]), account: harness.account)

        let source = FakeSuiStakingSource()
        source.answerResolve(with: [.unresolved(.expiredWithoutProof)])
        let reopened = SuiStakingPositionLoader(databaseService: harness.database, source: source, onResolved: { _ in })

        await reopened.reconcilePending(harness.account, accountId: harness.accountId)

        #expect(try await reopened.pendingSubmissions(accountId: harness.accountId).count == 1)
        let update = await reopened.latestUpdate(for: Base58.encode(prepared.digest))
        #expect(update == .unresolved(.expiredWithoutProof))
    }

    @Test func checkAgainSendsAStillValidSubmissionAgainByteForByte() async throws {
        let harness = try await Harness()
        let prepared = try await harness.prepare(try suiPrepared())
        _ = try await harness.service.submit(prepared, signature: Data([1]), account: harness.account)

        try await harness.service.checkAgain(harness.account)

        #expect(harness.source.broadcasts == [true, false])
        #expect(try await harness.pending().count == 1)
    }

    // MARK: Preparing

    @Test func preparingCreatesThePositionRowAndMapsWalletKitErrors() async throws {
        let harness = try await Harness()
        harness.source.answerRead(with: .success(suiRead(positions: [suiPosition()])))
        harness.source.answerPrepare(with: .failure(SuiStakingError.stakeChanged))

        await #expect(throws: SuiStakingServiceError.stakeChanged) {
            try await harness.service.prepare(.unstake(suiStakedSui()), account: harness.account)
        }

        #expect(try storedStakingRows(harness.database).count == 1)

        harness.source.answerPrepare(with: .failure(SuiStakingError.insufficientFunds(needed: 2, available: 1)))
        await #expect(throws: SuiStakingServiceError.insufficientBalance) {
            try await harness.service.prepare(.unstake(suiStakedSui()), account: harness.account)
        }

        harness.source.answerPrepare(with: .failure(SuiStakingError.belowMinimumStake(minimum: 1_000_000_000)))
        await #expect(throws: SuiStakingServiceError.belowMinimum(1_000_000_000)) {
            try await harness.service.prepare(.unstake(suiStakedSui()), account: harness.account)
        }
    }

    @Test func anUnreadablePositionStopsPreparation() async throws {
        let harness = try await Harness()
        harness.source.answerRead(with: .failure(FakeSuiStakingSource.Failure()))

        await #expect(throws: FakeSuiStakingSource.Failure.self) {
            try await harness.service.prepare(.unstake(suiStakedSui()), account: harness.account)
        }
    }

    @Test func maxStakeKeepsGasAndTheUnstakeReserve() {
        #expect(SuiStakingService.maxStake(liquid: 10_000_000_000) == 10_000_000_000 - 25_000_000)
        #expect(SuiStakingService.maxStake(liquid: 1_000_000_000) == 0)
    }
}
