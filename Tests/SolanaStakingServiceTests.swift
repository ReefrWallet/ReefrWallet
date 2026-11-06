// Tests of Solana staking's rules (per action authority, lockup and amounts) and what becomes of
// a transaction: every outcome, what's recorded and when, and recovery after the app reopens.

import Foundation
import Testing
import WalletKit
@testable import ReefrWallet

@Suite(.timeLimit(.minutes(1)))
struct SolanaStakingValidationTests {
    private let clock = SolanaClock(epoch: 100, epochStartTimestamp: 0, slot: 0, unixTimestamp: 1_000)

    private func position(
        _ address: String = "a",
        status: SolanaStakeStatus = .active,
        stake: UInt64 = 5_000_000_000,
        staker: String = solanaOwner,
        withdrawer: String = solanaOwner,
        lockupTimestamp: Int64 = 0
    ) -> SolanaStakePosition {
        SolanaStakePosition(
            account: stakeAccount(
                address,
                stake: stake,
                staker: staker,
                withdrawer: withdrawer,
                lockupTimestamp: lockupTimestamp
            ),
            activation: .init(),
            status: status
        )
    }

    private func validate(
        _ action: SolanaStakingAction,
        positions: [SolanaStakePosition] = [],
        balance: UInt64 = 100_000_000_000
    ) throws {
        try SolanaStakingService.validate(
            action,
            owner: solanaOwner,
            positions: positions,
            clock: clock,
            balance: balance,
            minimum: 1_000_000_000,
            rent: 2_282_880
        )
    }

    // MARK: Stake

    @Test func stakeMustMeetTheMinimum() {
        #expect(throws: SolanaStakingError.belowMinimum(1_000_000_000)) {
            try validate(.stake(lamports: 999_999_999, voter: "v"))
        }
    }

    @Test func stakeMustLeaveRoomForRent() {
        #expect(throws: SolanaStakingError.insufficientBalance) {
            try validate(.stake(lamports: 1_000_000_000, voter: "v"), balance: 1_000_000_001)
        }

        #expect(throws: Never.self) {
            try validate(.stake(lamports: 1_000_000_000, voter: "v"), balance: 1_002_282_880)
        }
    }

    @Test func maxStakeKeepsRentAndTheReserve() {
        #expect(SolanaStakingService.maxStake(balance: 1_000_000_000, rent: 2_282_880) == 987_717_120)
        #expect(SolanaStakingService.maxStake(balance: 1_000, rent: 2_282_880) == 0)
    }

    // MARK: Authority

    @Test func unstakeNeedsTheStaker() {
        #expect(throws: SolanaStakingError.cannotUnstake) {
            try validate(.unstake(accounts: ["a"]), positions: [position(staker: solanaOtherWallet)])
        }
    }

    @Test func unstakeDoesNotNeedTheWithdrawer() throws {
        try validate(.unstake(accounts: ["a"]), positions: [position(withdrawer: solanaOtherWallet)])
    }

    @Test func lockupDoesNotBlockUnstaking() throws {
        try validate(.unstake(accounts: ["a"]), positions: [position(lockupTimestamp: 9_999)])
    }

    @Test func aPartialIsBlockedWhenAnotherWalletWouldGetTheRent() {
        #expect(throws: SolanaStakingError.partialNeedsWithdrawAuthority) {
            try validate(
                .unstakePartial(account: "a", lamports: 2_000_000_000),
                positions: [position(withdrawer: solanaOtherWallet)]
            )
        }
    }

    @Test func aPartialOnALockedAccountIsAllowed() throws {
        try validate(
            .unstakePartial(account: "a", lamports: 2_000_000_000),
            positions: [position(lockupTimestamp: 9_999)]
        )
    }

    @Test func withdrawNeedsTheWithdrawer() {
        #expect(throws: SolanaStakingError.cannotWithdraw) {
            try validate(
                .withdraw([.init(address: "a", lamports: 1)]),
                positions: [position(status: .inactive, withdrawer: solanaOtherWallet)]
            )
        }
    }

    @Test func withdrawDoesNotNeedTheStaker() throws {
        try validate(
            .withdraw([.init(address: "a", lamports: 1)]),
            positions: [position(status: .inactive, staker: solanaOtherWallet)]
        )
    }

    @Test func lockupBlocksWithdrawal() {
        #expect(throws: SolanaStakingError.cannotWithdraw) {
            try validate(
                .withdraw([.init(address: "a", lamports: 1)]),
                positions: [position(status: .inactive, lockupTimestamp: 9_999)]
            )
        }
    }

    @Test func withdrawWaitsForCooldown() {
        #expect(throws: SolanaStakingError.cannotWithdraw) {
            try validate(.withdraw([.init(address: "a", lamports: 1)]), positions: [position(status: .deactivating)])
        }
    }

    // MARK: Partial amounts

    @Test func partialAmountAndRemainderEachMeetTheMinimum() throws {
        let account = [position(stake: 5_000_000_000)]

        try validate(.unstakePartial(account: "a", lamports: 1_000_000_000), positions: account)
        try validate(.unstakePartial(account: "a", lamports: 4_000_000_000), positions: account)

        #expect(throws: SolanaStakingError.belowMinimum(1_000_000_000)) {
            try validate(.unstakePartial(account: "a", lamports: 999_999_999), positions: account)
        }

        #expect(throws: SolanaStakingError.remainderBelowMinimum(1_000_000_000)) {
            try validate(.unstakePartial(account: "a", lamports: 4_000_000_001), positions: account)
        }

        #expect(throws: SolanaStakingError.amountTooLarge) {
            try validate(.unstakePartial(account: "a", lamports: 5_000_000_000), positions: account)
        }
    }

    @Test func aPartialNeedsRentInTheWallet() {
        #expect(throws: SolanaStakingError.insufficientBalance) {
            try validate(
                .unstakePartial(account: "a", lamports: 2_000_000_000),
                positions: [position()],
                balance: 1
            )
        }
    }

    @Test func withdrawalsTakeTheLiveBalance() {
        let live = SolanaStakePosition(
            account: stakeAccount("a", lamports: 77),
            activation: .init(),
            status: .inactive
        )

        let action = SolanaStakingService.withLiveAmounts(
            .withdraw([.init(address: "a", lamports: 70)]),
            positions: [live]
        )

        #expect(action == .withdraw([.init(address: "a", lamports: 77)]))
    }

    @Test func emptySelectionsAreRefused() {
        #expect(throws: SolanaStakingError.nothingSelected) {
            try validate(.unstake(accounts: []))
        }

        #expect(throws: SolanaStakingError.nothingSelected) {
            try validate(.withdraw([]))
        }
    }
}

// MARK: - Submitting

@Suite(.timeLimit(.minutes(1)))
struct SolanaStakingSubmitTests {
    private struct Setup {
        let account: ReefrWallet.Account
        let changed: CallRecorder
        let databaseService: DatabaseService
        let loader: SolanaStakingPositionLoader
        let service: SolanaStakingService
        let source: FakeSolanaStakingSource
    }

    private let signature = Data(repeating: 7, count: 64)

    private func setup(withRow: Bool = true, pollLimit: Int = 3) async throws -> Setup {
        let databaseService = try makeDatabaseService()
        let account = try await makeSolanaStakingAccount(databaseService)
        let source = FakeSolanaStakingSource()
        let changed = CallRecorder()

        let loader = SolanaStakingPositionLoader(
            databaseService: databaseService,
            source: source,
            onResolved: { _ in changed.record() }
        )

        if withRow {
            // Before anything the service reads with the real clock.
            try await loader.record(read: solanaRead(), startedAt: .distantPast, account: account)
        }

        let service = SolanaStakingService(
            positionLoader: loader,
            source: source,
            confirmationPollInterval: .milliseconds(1),
            confirmationPollLimit: pollLimit,
            onChanged: { _ in changed.record() }
        )

        return Setup(
            account: account,
            changed: changed,
            databaseService: databaseService,
            loader: loader,
            service: service,
            source: source
        )
    }

    private func pending(_ setup: Setup) async throws -> [SolanaPendingSubmission] {
        try await storedSolanaDetails(setup.databaseService, setup.account).pendingSubmissions
    }

    @Test func broadcastsTheExactSignedBytes() async throws {
        let setup = try await setup()
        let prepared = solanaPrepared()

        _ = try await setup.service.submit(prepared, signature: signature, account: setup.account)

        #expect(setup.source.broadcasts.count == 1)
        #expect(setup.source.broadcasts.first?.unsigned == prepared.unsigned)
        #expect(setup.source.broadcasts.first?.signature == signature)
    }

    @Test func confirmedResolvesAndRefreshes() async throws {
        let setup = try await setup()

        let outcome = try await setup.service.submit(solanaPrepared(), signature: signature, account: setup.account)

        #expect(outcome == .confirmed)
        #expect(try await pending(setup).isEmpty)
        #expect(setup.changed.calls == 1)
    }

    @Test func onChainFailureResolvesAndRefreshesTheBalanceBecauseTheFeeWasCharged() async throws {
        let setup = try await setup()
        setup.source.update { $0.statuses = [.failed] }

        let outcome = try await setup.service.submit(solanaPrepared(), signature: signature, account: setup.account)

        #expect(outcome == .failed)
        #expect(try await pending(setup).isEmpty)
        #expect(setup.changed.calls == 1)
    }

    @Test func processedNeverResolves() async throws {
        let setup = try await setup()
        setup.source.update { $0.statuses = [.processed] }

        let outcome = try await setup.service.submit(solanaPrepared(), signature: signature, account: setup.account)

        #expect(outcome == .submitted(signature: SolanaRPCClient.signatureString(signature)))
        #expect(try await pending(setup).count == 1)
    }

    @Test func aProcessedStatusThatDisappearsStaysSubmitted() async throws {
        let setup = try await setup()
        setup.source.update { $0.statuses = [.processed, .notFound] }

        let outcome = try await setup.service.submit(solanaPrepared(), signature: signature, account: setup.account)

        #expect(outcome == .submitted(signature: SolanaRPCClient.signatureString(signature)))
        #expect(setup.changed.calls == 0)
    }

    @Test func aFailedRecordPreventsTheBroadcast() async throws {
        let setup = try await setup(withRow: false)

        await #expect(throws: (any Error).self) {
            try await setup.service.submit(solanaPrepared(), signature: signature, account: setup.account)
        }

        #expect(setup.source.broadcasts.isEmpty)
    }

    @Test func theRecordIsWrittenBeforeTheBroadcast() async throws {
        let setup = try await setup()
        // The broadcast fails ambiguously, so what's stored is what was written before it.
        setup.source.update {
            $0.broadcastError = URLError(.timedOut)
            $0.statuses = [.notFound]
        }

        _ = try await setup.service.submit(solanaPrepared(), signature: signature, account: setup.account)

        let stored = try await pending(setup)
        #expect(stored.count == 1)
        #expect(stored.first?.recentBlockhash == "hash")
        #expect(stored.first?.lastValidBlockHeight == 1_000)
        #expect(stored.first?.slotAtBuild == 1)
    }

    @Test func aTakenTooLongSignatureIsNeverSent() async throws {
        let setup = try await setup()
        setup.source.update { $0.blockHeight = 1_001 }

        await #expect(throws: SolanaStakingError.expiredBeforeSending) {
            try await setup.service.submit(solanaPrepared(), signature: signature, account: setup.account)
        }

        #expect(setup.source.broadcasts.isEmpty)
        #expect(try await pending(setup).isEmpty)
    }

    @Test func aNodeRejectionMeansNothingWasSubmitted() async throws {
        let setup = try await setup()
        setup.source.update {
            $0.broadcastError = BlockchainClientError.rpcError(code: -32_002, message: "Blockhash not found")
        }

        await #expect(throws: BlockchainClientError.self) {
            try await setup.service.submit(solanaPrepared(), signature: signature, account: setup.account)
        }

        #expect(try await pending(setup).isEmpty)
        #expect(setup.source.recorded.isEmpty)
    }

    @Test(arguments: [
        BlockchainClientError.transportError(reason: "timed out"),
        BlockchainClientError.invalidResponse(reason: "502")
    ])
    func anAmbiguousSendIsFollowedAndRecordedForHistory(error: BlockchainClientError) async throws {
        let setup = try await setup()
        setup.source.update {
            $0.broadcastError = error
            $0.statuses = [.notFound]
        }

        let outcome = try await setup.service.submit(solanaPrepared(), signature: signature, account: setup.account)
        let identifier = SolanaRPCClient.signatureString(signature)

        #expect(outcome == .submitted(signature: identifier))
        #expect(setup.source.recorded == [identifier])
        #expect(try await pending(setup).first?.signature == identifier)
    }

    @Test func anUnresolvedSubmissionBlocksNewActions() async throws {
        let setup = try await setup()
        try await setup.loader.addPending(solanaPending(), accountId: try idOf(setup.account))

        await #expect(throws: SolanaStakingError.submissionUnresolved) {
            try await setup.service.prepare(.unstake(accounts: ["a"]), account: setup.account)
        }
    }

    @Test func simulationFailureIsReportedAsNotSubmitted() async throws {
        let setup = try await setup()
        setup.source.update {
            $0.read = .success(solanaRead(accounts: [stakeAccount("a")]))
            $0.prepareError = SolanaStakingBuildError.simulationFailed("custom program error")
        }

        await #expect(throws: SolanaStakingError.simulationFailed("custom program error")) {
            try await setup.service.prepare(.unstake(accounts: ["a"]), account: setup.account)
        }

        #expect(setup.source.broadcasts.isEmpty)
    }

    @Test func prepareRecordsTheLiveRead() async throws {
        let setup = try await setup()
        setup.source.update {
            $0.read = .success(solanaRead(accounts: [stakeAccount("a")]))
        }

        _ = try await setup.service.prepare(.unstake(accounts: ["a"]), account: setup.account)

        let details = try await storedSolanaDetails(setup.databaseService, setup.account)
        #expect(details.positions.map(\.account.address) == ["a"])
    }

    // MARK: Recovery

    /// A new loader over the same store: what's left after the app reopens.
    private func reopened(
        _ setup: Setup,
        source: FakeSolanaStakingSource
    ) -> (SolanaStakingPositionLoader, CallRecorder) {
        let resolved = CallRecorder()

        return (
            SolanaStakingPositionLoader(
                databaseService: setup.databaseService,
                source: source,
                onResolved: { _ in resolved.record() }
            ),
            resolved
        )
    }

    @Test(arguments: [
        SolanaSubmissionUpdate.confirmed,
        SolanaSubmissionUpdate.failed,
        SolanaSubmissionUpdate.expired
    ])
    func recoveryAfterReopeningLiftsTheBlockOnceResolved(update: SolanaSubmissionUpdate) async throws {
        let setup = try await setup()
        try await setup.loader.addPending(solanaPending(), accountId: try idOf(setup.account))

        let source = FakeSolanaStakingSource()
        source.update { $0.reconcile = { _ in update } }
        let (loader, resolved) = reopened(setup, source: source)

        await loader.reconcilePending(setup.account, accountId: try idOf(setup.account))

        #expect(try await pending(setup).isEmpty)
        #expect(resolved.calls == 1)
    }

    @Test func recoveryAfterReopeningKeepsTheBlockWhileUnknown() async throws {
        let setup = try await setup()
        try await setup.loader.addPending(solanaPending(), accountId: try idOf(setup.account))

        let source = FakeSolanaStakingSource()
        source.update {
            $0.reconcile = { pending in
                var pending = pending
                pending.isPastValidity = true
                return .unresolved(pending)
            }
        }

        let (loader, resolved) = reopened(setup, source: source)

        await loader.reconcilePending(setup.account, accountId: try idOf(setup.account))

        #expect(try await pending(setup).first?.isPastValidity == true)
        #expect(resolved.calls == 0)
    }

    @Test func aReadRunsReconciliationEvenWhenItFails() async throws {
        let setup = try await setup()
        try await setup.loader.addPending(solanaPending(), accountId: try idOf(setup.account))

        let source = FakeSolanaStakingSource()
        source.update {
            $0.read = .failure(BlockchainClientError.transportError(reason: "down"))
            $0.reconcile = { _ in .confirmed }
        }

        let (loader, _) = reopened(setup, source: source)
        let accountId = try idOf(setup.account)

        await #expect(throws: BlockchainClientError.self) {
            try await loader.load(setup.account, accountId: accountId)
        }

        await loader.reconcilePending(setup.account, accountId: accountId)
        #expect(try await pending(setup).isEmpty)
    }
}

extension SolanaSubmissionUpdate: @retroactive CustomTestStringConvertible {
    public var testDescription: String {
        switch self {
        case .confirmed: "confirmed"
        case .expired: "expired"
        case .failed: "failed"
        case .unresolved: "unresolved"
        }
    }
}
