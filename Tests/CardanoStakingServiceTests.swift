// Tests of Cardano staking's rules, what becomes of a transaction, and the two-step workflow a
// withdrawal or deregistration needs when no DRep is delegated yet (ADR-059).

import BigInt
import Foundation
import Testing
import WalletKit
@testable import ReefrWallet

private let ledgerRejection = WalletKitError.internalError(
    message: "Blockfrost rejected tx/submit: {\"status_code\":400,\"message\":\"BadInputsUTxO\"}"
)

// MARK: - Validation

@Suite(.timeLimit(.minutes(1)))
struct CardanoStakingValidationTests {
    private func validate(_ action: CardanoStakingAction, read: CardanoStakingRead) throws {
        try CardanoStakingService.validate(action, read: read)
    }

    @Test func stakeNeedsAnUnregisteredKey() {
        #expect(throws: CardanoStakingFailure.alreadyRegistered) {
            try validate(.stake(pool: "pool1a", drep: nil), read: cardanoRead())
        }

        #expect(throws: Never.self) {
            try validate(.stake(pool: "pool1a", drep: nil), read: cardanoRead(registered: false))
        }
    }

    @Test func changesNeedARegisteredKeyAndAnActualChange() {
        #expect(throws: CardanoStakingFailure.notRegistered) {
            try validate(.changePool("pool1b"), read: cardanoRead(registered: false))
        }

        #expect(throws: CardanoStakingFailure.unchanged) {
            try validate(.changePool("pool1a"), read: cardanoRead())
        }

        #expect(throws: CardanoStakingFailure.unchanged) {
            try validate(.changeDRep(.abstain), read: cardanoRead())
        }

        #expect(throws: Never.self) {
            try validate(.changeDRep(.noConfidence), read: cardanoRead())
        }
    }

    @Test func withdrawNeedsRewardsAndADRep() {
        #expect(throws: CardanoStakingFailure.noRewards) {
            try validate(.withdraw, read: cardanoRead(rewards: 0))
        }

        #expect(throws: CardanoStakingFailure.drepRequired) {
            try validate(.withdraw, read: cardanoRead(drep: nil))
        }

        #expect(throws: Never.self) {
            try validate(.withdraw, read: cardanoRead())
        }
    }

    @Test func stopStakingNeedsAKnownRefundAndSweepsRewardsBehindADRep() {
        #expect(throws: CardanoStakingFailure.missingRefund) {
            try validate(.stopStaking, read: cardanoRead(refund: nil))
        }

        #expect(throws: CardanoStakingFailure.drepRequired) {
            try validate(.stopStaking, read: cardanoRead(drep: nil))
        }

        #expect(throws: Never.self) {
            try validate(.stopStaking, read: cardanoRead(drep: nil, rewards: 0))
        }
    }

    @Test func watchOnlyAndTrezorOnPhoneAreRefusedBeforeAnyPrompt() {
        #expect(throws: CardanoStakingFailure.watchOnly) {
            try CardanoStakingService.requireSigner(.watchOnly)
        }

        #expect(throws: Never.self) {
            try CardanoStakingService.requireSigner(.local)
        }

        #if os(iOS)
        #expect(throws: CardanoStakingFailure.trezorUnavailable) {
            try CardanoStakingService.requireSigner(.trezor)
        }
        #endif
    }
}

// MARK: - Preparation and submission

struct CardanoStakingSetup {
    let account: ReefrWallet.Account
    let changed: CallRecorder
    let databaseService: DatabaseService
    let loader: CardanoStakingPositionLoader
    let service: CardanoStakingService
    let source: FakeCardanoStakingSource

    static func make(read: CardanoStakingRead = cardanoRead(), pollLimit: Int = 3) async throws -> CardanoStakingSetup {
        let databaseService = try makeDatabaseService()
        let account = try await makeCardanoStakingAccount(databaseService)
        let source = FakeCardanoStakingSource()
        let changed = CallRecorder()
        source.update { $0.read = .success(read) }

        let loader = CardanoStakingPositionLoader(
            databaseService: databaseService,
            source: source,
            onResolved: { _ in changed.record() }
        )

        try await loader.record(read: read, startedAt: .distantPast, account: account)

        let service = CardanoStakingService(
            positionLoader: loader,
            source: source,
            confirmationPollInterval: .milliseconds(1),
            confirmationPollLimit: pollLimit,
            onChanged: { _ in changed.record() }
        )

        return CardanoStakingSetup(
            account: account,
            changed: changed,
            databaseService: databaseService,
            loader: loader,
            service: service,
            source: source
        )
    }

    var pending: [CardanoPendingSubmission] {
        get async throws { try await storedCardanoDetails(databaseService, account).pendingSubmissions }
    }

    var workflow: CardanoStakingWorkflow? {
        get async throws { try await storedCardanoDetails(databaseService, account).workflow }
    }
}

@Suite(.timeLimit(.minutes(1)))
struct CardanoStakingSubmitTests {
    private let signed = Data("signed".utf8)

    @Test func prepareRevalidatesThePoolAndDRepJustBeforeBuilding() async throws {
        let setup = try await CardanoStakingSetup.make(read: cardanoRead(registered: false))
        setup.source.update { $0.pool = nil }

        await #expect(throws: CardanoStakingFailure.poolUnavailable) {
            try await setup.service.prepare(.stake(pool: "pool1a", drep: nil), account: setup.account, signer: .local)
        }

        setup.source.update {
            $0.pool = CardanoPool(fixedCost: 0, marginCost: 0, name: nil, poolId: "pool1a", saturation: 0, ticker: nil)
            $0.drep = CardanoDRepInfo(drepId: "drep1x", isActive: false, name: nil)
        }

        await #expect(throws: CardanoStakingFailure.drepUnavailable) {
            try await setup.service.prepare(
                .stake(pool: "pool1a", drep: .id("drep1x")),
                account: setup.account,
                signer: .local
            )
        }

        #expect(setup.source.preparedActions.isEmpty)
    }

    @Test func prepareStopsWhileASubmissionIsPending() async throws {
        let setup = try await CardanoStakingSetup.make()
        try await setup.loader.addPending(
            CardanoPendingSubmission(hash: "h", ttl: 5_000),
            accountId: idOf(setup.account)
        )

        await #expect(throws: CardanoStakingFailure.submissionUnresolved) {
            try await setup.service.prepare(.changeDRep(.noConfidence), account: setup.account, signer: .local)
        }
    }

    @Test func prepareBuildsAValidAction() async throws {
        let setup = try await CardanoStakingSetup.make()

        _ = try await setup.service.prepare(.changeDRep(.noConfidence), account: setup.account, signer: .local)

        #expect(setup.source.preparedActions == [.changeDRep(.noConfidence)])
    }

    @Test func aTransactionWithLittleValidityLeftIsNotSent() async throws {
        let setup = try await CardanoStakingSetup.make()
        setup.source.update { $0.secondsRemaining = 599 }

        await #expect(throws: CardanoStakingFailure.expiredBeforeSending) {
            try await setup.service.submit(cardanoPrepared(), signed: signed, account: setup.account)
        }

        #expect(setup.source.broadcasts.isEmpty)
        #expect(try await setup.pending.isEmpty)
    }

    @Test func broadcastsTheExactSignedBytesAfterRecordingThem() async throws {
        let setup = try await CardanoStakingSetup.make()

        _ = try await setup.service.submit(cardanoPrepared(), signed: signed, account: setup.account)

        #expect(setup.source.broadcasts == [signed])
    }

    @Test func confirmedResolvesAndRefreshesThePositionAndBalances() async throws {
        let setup = try await CardanoStakingSetup.make()

        let outcome = try await setup.service.submit(cardanoPrepared(), signed: signed, account: setup.account)

        #expect(outcome == .confirmed)
        #expect(try await setup.pending.isEmpty)
        #expect(setup.changed.calls == 1)
    }

    @Test func aLedgerRejectionMeansNotSubmitted() async throws {
        let setup = try await CardanoStakingSetup.make()
        setup.source.update { $0.broadcastError = ledgerRejection }

        await #expect(throws: CardanoStakingFailure.self) {
            try await setup.service.submit(cardanoPrepared(), signed: signed, account: setup.account)
        }

        #expect(try await setup.pending.isEmpty)
    }

    @Test func anyOtherSendFailureStaysPendingAndIsFollowed() async throws {
        let setup = try await CardanoStakingSetup.make()
        setup.source.update {
            $0.broadcastError = URLError(.timedOut)
            $0.defaultState = .pending
        }

        let outcome = try await setup.service.submit(cardanoPrepared(), signed: signed, account: setup.account)
        let hash = try cardanoPrepared().hash()

        #expect(outcome == .submitted(hash: hash))
        #expect(try await setup.pending.map(\.hash) == [hash])
        #expect(setup.changed.calls == 0)
    }

    @Test func anExpiredTransactionResolvesAsExpired() async throws {
        let setup = try await CardanoStakingSetup.make()
        setup.source.update { $0.defaultState = .expired }

        let outcome = try await setup.service.submit(cardanoPrepared(), signed: signed, account: setup.account)

        #expect(outcome == .expired(hash: try cardanoPrepared().hash()))
        #expect(try await setup.pending.isEmpty)
    }

    @Test func reconciliationResolvesAPendingSubmissionAfterARelaunch() async throws {
        let setup = try await CardanoStakingSetup.make()
        setup.source.update { $0.defaultState = .pending }
        _ = try await setup.service.submit(cardanoPrepared(), signed: signed, account: setup.account)

        // A fresh loader over the same store, as after a relaunch.
        let changed = setup.changed
        let relaunched = CardanoStakingPositionLoader(
            databaseService: setup.databaseService,
            source: setup.source,
            onResolved: { _ in changed.record() }
        )

        setup.source.update { $0.defaultState = .confirmed }
        await relaunched.reconcilePending(setup.account, accountId: try idOf(setup.account))

        #expect(try await setup.pending.isEmpty)
        #expect(setup.changed.calls == 1)
    }
}

// MARK: - Workflow

@Suite(.timeLimit(.minutes(1)))
struct CardanoStakingWorkflowTests {
    private let signed = Data("signed".utf8)

    private func startStepOne(_ setup: CardanoStakingSetup) async throws -> CardanoStakingOutcome {
        try await setup.service.submit(
            cardanoPrepared(byte: 1),
            signed: signed,
            account: setup.account,
            role: .voteDelegation(intent: .withdraw, drep: .abstain)
        )
    }

    private func stepTwo(_ setup: CardanoStakingSetup) async throws -> CardanoStakingOutcome {
        try await setup.service.submit(
            cardanoPrepared(byte: 2),
            signed: signed,
            account: setup.account,
            role: .finalStep
        )
    }

    @Test func theWorkflowIsStoredBeforeStepOneIsBroadcast() async throws {
        let setup = try await CardanoStakingSetup.make(read: cardanoRead(drep: nil))
        setup.source.update { $0.defaultState = .pending }

        _ = try await startStepOne(setup)

        let hash = try cardanoPrepared(byte: 1).hash()
        #expect(try await setup.workflow?.phase == .voteDelegationPending(hash: hash))
        #expect(try await setup.workflow?.intent == .withdraw)
    }

    @Test func reopeningAfterStepOneConfirmsResumesAtTheFinalStepOnceTheReadShowsTheDRep() async throws {
        let setup = try await CardanoStakingSetup.make(read: cardanoRead(drep: nil))
        setup.source.update { $0.defaultState = .confirmed }
        _ = try await startStepOne(setup)

        // Confirmed, but the read doesn't show the DRep yet.
        try await setup.loader.load(setup.account, accountId: idOf(setup.account))
        let hash = try cardanoPrepared(byte: 1).hash()
        #expect(try await setup.workflow?.phase == .voteDelegationPending(hash: hash))

        setup.source.update { $0.read = .success(cardanoRead(drep: .abstain)) }
        try await setup.loader.load(setup.account, accountId: idOf(setup.account))

        #expect(try await setup.workflow?.phase == .readyForFinalStep(notice: nil))
    }

    @Test func stepOneRejectedReturnsToItsStartWithANotice() async throws {
        let setup = try await CardanoStakingSetup.make(read: cardanoRead(drep: nil))
        setup.source.update { $0.broadcastError = ledgerRejection }

        await #expect(throws: CardanoStakingFailure.self) { try await startStepOne(setup) }

        #expect(try await setup.workflow?.phase == .needsVoteDelegation(notice: .failed))
        #expect(try await setup.pending.isEmpty)
    }

    @Test func stepOneExpiredReturnsToItsStartWithANotice() async throws {
        let setup = try await CardanoStakingSetup.make(read: cardanoRead(drep: nil))
        setup.source.update { $0.defaultState = .expired }

        _ = try await startStepOne(setup)

        #expect(try await setup.workflow?.phase == .needsVoteDelegation(notice: .expired))
    }

    @Test func retryingStepOneWithAnotherDRepStoresTheNewOne() async throws {
        let setup = try await CardanoStakingSetup.make(read: cardanoRead(drep: nil))
        setup.source.update { $0.broadcastError = ledgerRejection }
        await #expect(throws: CardanoStakingFailure.self) { try await startStepOne(setup) }

        setup.source.update {
            $0.broadcastError = nil
            $0.defaultState = .confirmed
        }

        _ = try await setup.service.submit(
            cardanoPrepared(byte: 3),
            signed: signed,
            account: setup.account,
            role: .voteDelegation(intent: .withdraw, drep: .noConfidence)
        )

        try await setup.loader.load(setup.account, accountId: idOf(setup.account))
        #expect(try await setup.workflow?.drep == .noConfidence)

        // The read shows the DRep that was sent, so the final step is ready.
        setup.source.update { $0.read = .success(cardanoRead(drep: .noConfidence)) }
        try await setup.loader.load(setup.account, accountId: idOf(setup.account))
        #expect(try await setup.workflow?.phase == .readyForFinalStep(notice: nil))
    }

    @Test func stepTwoRejectedOrExpiredReturnsToReadyWithANotice() async throws {
        let setup = try await CardanoStakingSetup.make()
        try await setup.loader.setWorkflow(
            cardanoWorkflow(.readyForFinalStep(notice: nil)),
            accountId: idOf(setup.account)
        )

        setup.source.update { $0.broadcastError = ledgerRejection }
        await #expect(throws: CardanoStakingFailure.self) { try await stepTwo(setup) }

        #expect(try await setup.workflow?.phase == .readyForFinalStep(notice: .failed))

        setup.source.update {
            $0.broadcastError = nil
            $0.defaultState = .expired
        }

        _ = try await stepTwo(setup)

        #expect(try await setup.workflow?.phase == .readyForFinalStep(notice: .expired))
    }

    @Test func stepTwoConfirmedClearsTheWorkflow() async throws {
        let setup = try await CardanoStakingSetup.make()
        try await setup.loader.setWorkflow(
            cardanoWorkflow(.readyForFinalStep(notice: nil)),
            accountId: idOf(setup.account)
        )

        let outcome = try await stepTwo(setup)

        #expect(outcome == .confirmed)
        #expect(try await setup.workflow == nil)
    }

    @Test func cancelClearsTheWorkflowButKeepsAPendingSubmissionBlocking() async throws {
        let setup = try await CardanoStakingSetup.make(read: cardanoRead(drep: nil))
        setup.source.update { $0.defaultState = .pending }
        _ = try await startStepOne(setup)

        try await setup.service.cancelWorkflow(setup.account)

        #expect(try await setup.workflow == nil)
        #expect(try await setup.pending.count == 1)

        await #expect(throws: CardanoStakingFailure.submissionUnresolved) {
            try await setup.service.prepare(.changeDRep(.noConfidence), account: setup.account, signer: .local)
        }

        // Resolving it with no workflow stored only refreshes.
        setup.source.update { $0.defaultState = .confirmed }
        try await setup.service.checkAgain(setup.account)

        #expect(try await setup.workflow == nil)
        #expect(try await setup.pending.isEmpty)
        #expect(setup.changed.calls == 1)
    }

    @Test func aWorkflowSurvivesARelaunchAndIsNotOverwrittenByReads() async throws {
        let setup = try await CardanoStakingSetup.make(read: cardanoRead(drep: nil))
        let stored = cardanoWorkflow(.needsVoteDelegation(notice: .expired), intent: .stopStaking, drep: .noConfidence)
        try await setup.loader.setWorkflow(stored, accountId: idOf(setup.account))

        let relaunched = CardanoStakingPositionLoader(databaseService: setup.databaseService, source: setup.source)
        try await relaunched.load(setup.account, accountId: idOf(setup.account))

        #expect(try await setup.workflow == stored)
    }

    @Test func resolvingOnlyTouchesAWorkflowWaitingOnThatSubmission() {
        let waiting = cardanoWorkflow(.finalStepPending(hash: "h"))

        #expect(CardanoStakingPositionLoader.resolved(waiting, hash: "other", state: .expired) == waiting)
        #expect(CardanoStakingPositionLoader.resolved(waiting, hash: "h", state: .confirmed) == nil)
        #expect(
            CardanoStakingPositionLoader.resolved(waiting, hash: "h", state: .expired)?.phase
                == .readyForFinalStep(notice: .expired)
        )
    }
}

// MARK: - Store

@Suite(.timeLimit(.minutes(1)))
struct CardanoStakingStoreTests {
    @Test func aReadStoresTheDelegationNamesAndRewards() async throws {
        let setup = try await CardanoStakingSetup.make()

        try await setup.loader.load(setup.account, accountId: idOf(setup.account))

        let details = try await storedCardanoDetails(setup.databaseService, setup.account)
        let staking = try await setup.databaseService.fetchStaking(accountId: idOf(setup.account))

        #expect(details.registered)
        #expect(details.pool?.ticker == "EVER")
        #expect(details.refundDeposit == 2_000_000)
        #expect(details.totalEarned == 96_200_000)
        #expect(staking?.staked == 1_250_000_000)
        #expect(staking?.rewards == 5_000_000)
    }

    @Test func aFailedNameLookupKeepsTheStoredNames() async throws {
        let setup = try await CardanoStakingSetup.make()
        try await setup.loader.load(setup.account, accountId: idOf(setup.account))

        setup.source.update { $0.pool = nil }
        try await setup.loader.load(setup.account, accountId: idOf(setup.account))

        let details = try await storedCardanoDetails(setup.databaseService, setup.account)
        #expect(details.pool?.ticker == "EVER")
        #expect(details.pool?.name == "Everstake")
    }

    @Test func anOlderReadDoesNotUndoANewerOne() async throws {
        let setup = try await CardanoStakingSetup.make()
        try await setup.loader.record(read: cardanoRead(rewards: 9), startedAt: .now, account: setup.account)

        try await setup.loader.record(
            read: cardanoRead(rewards: 1),
            startedAt: .distantPast + 1,
            account: setup.account
        )

        let staking = try await setup.databaseService.fetchStaking(accountId: idOf(setup.account))
        #expect(staking?.rewards == 9)
    }

    @Test func theStakingStateServiceRoutesCardanoToItsLoader() async throws {
        let setup = try await CardanoStakingSetup.make(read: cardanoRead(registered: false))
        let service = StakingStateService(loaders: [setup.loader])

        try await service.refresh(setup.account)

        #expect(try await storedCardanoDetails(setup.databaseService, setup.account).registered == false)
    }
} // swiftlint:disable:this file_length
