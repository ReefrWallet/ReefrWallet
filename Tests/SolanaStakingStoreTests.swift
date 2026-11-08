// Tests of the stored Solana position: what a read may replace, retired addresses, when rewards are
// asked for and how they read, timing, and the loader's failure behavior.

import Foundation
import SwiftData
import Testing
import WalletKit
@testable import ReefrWallet

@Suite(.timeLimit(.minutes(1)))
struct SolanaStakingStoreTests {
    private struct Setup {
        let account: ReefrWallet.Account
        let databaseService: DatabaseService
        let loader: SolanaStakingPositionLoader
        let source: FakeSolanaStakingSource
    }

    private func setup() async throws -> Setup {
        let databaseService = try makeDatabaseService()
        let source = FakeSolanaStakingSource()

        return Setup(
            account: try await makeSolanaStakingAccount(databaseService),
            databaseService: databaseService,
            loader: SolanaStakingPositionLoader(
                databaseService: databaseService,
                source: source,
                onResolved: { _ in }
            ),
            source: source
        )
    }

    @discardableResult
    private func save(
        _ setup: Setup,
        _ read: SolanaStakingRead,
        rewards: SolanaStakingRewards? = nil,
        validators: [String: SolanaStakingDetails.Validator] = [:],
        at seconds: TimeInterval
    ) async throws -> SolanaStakingDetails {
        try await setup.databaseService.saveStakingState(
            accountId: try idOf(setup.account),
            observation: SolanaStakingObservation(read: read, rewards: rewards, validators: validators),
            startedAt: stakingDate(seconds)
        )

        return try await storedSolanaDetails(setup.databaseService, setup.account)
    }

    // MARK: Rows

    @Test func solanaRowsDecode() async throws {
        let setup = try await setup()
        let details = try await save(setup, solanaRead(accounts: [stakeAccount("a")]), at: 1)

        #expect(details.positions.map(\.account.address) == ["a"])
        #expect(details.version == SolanaStakingDetails.currentVersion)
    }

    @Test func aWrongVersionReadsAsNoRow() throws {
        var details = SolanaStakingDetails(
            clock: SolanaClock(epoch: 1, epochStartTimestamp: 0, slot: 0, unixTimestamp: 0),
            discovery: .complete,
            observedAt: Date(),
            pendingSubmissions: [],
            positions: [],
            retiredAddresses: [:],
            slotsRemainingInEpoch: 0,
            validators: [:]
        )

        #expect(StakingDetails.solana(details).isCurrentVersion)

        details.version = 99
        #expect(!StakingDetails.solana(details).isCurrentVersion)
    }

    @Test func anOlderReadDoesNotOverwriteANewerOne() async throws {
        let setup = try await setup()

        try await save(setup, solanaRead(accounts: [stakeAccount("new")]), at: 10)
        let details = try await save(setup, solanaRead(accounts: [stakeAccount("old")]), at: 5)

        #expect(details.positions.map(\.account.address) == ["new"])
    }

    // MARK: Discovery

    @Test func aDegradedReadKeepsWhatItReturnsAndIsMarked() async throws {
        let setup = try await setup()

        try await save(setup, solanaRead(accounts: [stakeAccount("a"), stakeAccount("b")]), at: 1)

        let details = try await save(
            setup,
            solanaRead(accounts: [stakeAccount("a"), stakeAccount("b")], discovery: .degraded),
            at: 2
        )

        #expect(details.discovery == .degraded)
        #expect(details.positions.count == 2)
    }

    @Test func aCompleteReadClearsDegraded() async throws {
        let setup = try await setup()

        try await save(setup, solanaRead(discovery: .degraded), at: 1)
        let details = try await save(setup, solanaRead(discovery: .complete), at: 2)

        #expect(details.discovery == .complete)
    }

    @Test func aClosedAccountDropsAndIsRetired() async throws {
        let setup = try await setup()

        try await save(setup, solanaRead(accounts: [stakeAccount("a")], epoch: 100), at: 1)
        let details = try await save(setup, solanaRead(accounts: [], epoch: 100), at: 2)

        #expect(details.positions.isEmpty)
        #expect(details.retiredAddresses == ["a": 100])
    }

    @Test func aReadFailureLeavesTheStoredPositionIntact() async throws {
        let setup = try await setup()
        let accountId = try idOf(setup.account)

        setup.source.update { $0.read = .success(solanaRead(accounts: [stakeAccount("a")])) }
        try await setup.loader.load(setup.account, accountId: accountId)

        let before = try await storedSolanaDetails(setup.databaseService, setup.account)

        setup.source.update { $0.read = .failure(BlockchainClientError.transportError(reason: "down")) }

        await #expect(throws: BlockchainClientError.self) {
            try await setup.loader.load(setup.account, accountId: accountId)
        }

        #expect(try await storedSolanaDetails(setup.databaseService, setup.account) == before)
        #expect(setup.source.knownSeen.last == ["a"])
    }

    @Test func aReadKeepsPendingSubmissions() async throws {
        let setup = try await setup()

        try await save(setup, solanaRead(), at: 1)
        try await setup.loader.addPending(solanaPending(), accountId: try idOf(setup.account))

        let details = try await save(setup, solanaRead(accounts: [stakeAccount("a")]), at: 2)

        #expect(details.pendingSubmissions == [solanaPending()])
    }

    @Test func aFailedLookupKeepsValidatorNames() async throws {
        let setup = try await setup()
        let named = ["voter": SolanaStakingDetails.Validator(commission: 7, name: "Everstake", apy: 6.84)]

        try await save(setup, solanaRead(accounts: [stakeAccount("a")]), validators: named, at: 1)
        let details = try await save(setup, solanaRead(accounts: [stakeAccount("a")]), at: 2)

        #expect(details.validators["voter"]?.name == "Everstake")
        #expect(details.apy == 6.84)
    }

    // MARK: Retired retention

    private func stored(_ accounts: [SolanaStakeAccount], retired: [String: UInt64] = [:]) -> SolanaStakingDetails {
        SolanaStakingDetails(
            clock: SolanaClock(epoch: 100, epochStartTimestamp: 0, slot: 0, unixTimestamp: 0),
            discovery: .complete,
            observedAt: Date(),
            pendingSubmissions: [],
            positions: accounts.map { SolanaStakePosition(account: $0, activation: .init(), status: .active) },
            retiredAddresses: retired,
            slotsRemainingInEpoch: 0,
            validators: [:]
        )
    }

    /// Last seen in 100, earned in 103, closed, wallet reopens in 104.
    @Test func theDetectionEpochKeepsAnOfflineGapsRewardQueryable() {
        let retired = SolanaStakingDetails.retired(
            stored([stakeAccount("a")]),
            read: solanaRead(accounts: [], epoch: 104)
        )

        #expect(retired == ["a": 104])
    }

    @Test func retiredIsKeptThroughTheTargetEpochThenDropped() {
        let previous = stored([], retired: ["a": 104])

        #expect(SolanaStakingDetails.retired(previous, read: solanaRead(epoch: 104)) == ["a": 104])
        #expect(SolanaStakingDetails.retired(previous, read: solanaRead(epoch: 105)) == ["a": 104])
        #expect(SolanaStakingDetails.retired(previous, read: solanaRead(epoch: 106)).isEmpty)
    }

    @Test func anAccountThatReturnsIsNoLongerRetired() {
        let retired = SolanaStakingDetails.retired(
            stored([], retired: ["a": 100]),
            read: solanaRead(accounts: [stakeAccount("a")], epoch: 100)
        )

        #expect(retired.isEmpty)
    }

    // MARK: Asking for rewards

    private func rewards(
        epoch: UInt64 = 99,
        lamports: UInt64 = 10,
        queried: [String] = ["a"],
        unknown: [String] = [],
        attemptedAt: Date = stakingDate(0)
    ) -> SolanaStakingRewards {
        SolanaStakingRewards(
            attemptedAt: attemptedAt,
            epoch: epoch,
            lamports: lamports,
            queriedAddresses: queried,
            unknownAddresses: unknown
        )
    }

    @Test func aResolvedAnswerIsCachedForTheEpochAndAddresses() {
        let answer = rewards()

        func needsRewards(
            _ stored: SolanaStakingRewards?, epoch: UInt64, addresses: Set<String>, at seconds: TimeInterval
        ) -> Bool {
            SolanaStakingDetails.needsRewards(
                stored: stored, epoch: epoch, addresses: addresses, now: stakingDate(seconds)
            )
        }

        #expect(!needsRewards(answer, epoch: 99, addresses: ["a"], at: 99_999))
        #expect(needsRewards(answer, epoch: 100, addresses: ["a"], at: 0))
        #expect(needsRewards(answer, epoch: 99, addresses: ["a", "b"], at: 0))
        #expect(needsRewards(nil, epoch: 99, addresses: ["a"], at: 0))
    }

    @Test func unknownsRetryHourly() {
        let answer = rewards(unknown: ["a"])

        func needsRewards(at seconds: TimeInterval) -> Bool {
            SolanaStakingDetails.needsRewards(
                stored: answer, epoch: 99, addresses: ["a"], now: stakingDate(seconds)
            )
        }

        #expect(!needsRewards(at: 3_599))
        #expect(needsRewards(at: 3_600))
    }

    @Test func aFailedLookupKeepsTheOlderAnswerUnderItsOwnEpoch() async throws {
        let setup = try await setup()
        let accountId = try idOf(setup.account)
        let older = rewards(epoch: 98, lamports: 3)

        try await save(setup, solanaRead(accounts: [stakeAccount("a")]), rewards: older, at: 1)

        setup.source.update {
            $0.read = .success(solanaRead(accounts: [stakeAccount("a")]))
            $0.rewards = .failure(BlockchainClientError.transportError(reason: "down"))
        }

        try await setup.loader.load(setup.account, accountId: accountId)

        let details = try await storedSolanaDetails(setup.databaseService, setup.account)
        #expect(details.rewards == older)
        #expect(setup.source.rewardCalls == 1)

        let staking = try await setup.databaseService.fetchStaking(accountId: accountId)
        #expect(staking?.rewards == 0)
    }

    // MARK: Rewards text

    private func details(
        rewards: SolanaStakingRewards?,
        discovery: SolanaStakeDiscovery = .complete,
        accounts: [SolanaStakeAccount] = [stakeAccount("a")]
    ) -> SolanaStakingDetails {
        var result = stored(accounts)
        result.discovery = discovery
        result.rewards = rewards
        result.validators = ["voter": .init(commission: 7, name: "E", apy: 6.84)]
        return result
    }

    private func line(_ details: SolanaStakingDetails) -> String? {
        SolanaStakingModel.rewardsLine(details: details, solPrice: nil)
    }

    @Test func completeLastEpoch() {
        #expect(line(details(rewards: rewards(lamports: 4_100_000)))?.hasPrefix("Last epoch: \(SolanaStakingFormat.sol(4_100_000))") == true)
    }

    @Test func unknownsQualifyTheTotal() {
        let text = line(details(rewards: rewards(lamports: 4_100_000, unknown: ["b"])))
        #expect(text?.hasPrefix("Last epoch: at least \(SolanaStakingFormat.sol(4_100_000))") == true)
    }

    @Test func degradedDiscoveryQualifiesTheTotal() {
        let text = line(details(rewards: rewards(lamports: 4_100_000), discovery: .degraded))
        #expect(text?.hasPrefix("Last epoch: at least") == true)
    }

    @Test func anUnknownZeroIsNeverShownAsZero() {
        let unknown = line(details(rewards: rewards(lamports: 0, unknown: ["a"])))
        let degraded = line(details(rewards: rewards(lamports: 0), discovery: .degraded))

        #expect(unknown?.hasPrefix("Rewards unavailable") == true)
        #expect(degraded?.hasPrefix("Rewards unavailable") == true)
    }

    @Test func noAnswerIsUnavailable() {
        #expect(line(details(rewards: nil))?.hasPrefix("Rewards unavailable") == true)
    }

    @Test func anOlderEpochIsNamed() {
        let text = line(details(rewards: rewards(epoch: 98, lamports: 3_900_000)))
        #expect(text?.hasPrefix("Epoch 98: \(SolanaStakingFormat.sol(3_900_000))") == true)
    }

    @Test func anOlderEpochIsQualifiedTheSameWay() {
        let text = line(details(rewards: rewards(epoch: 98, lamports: 3_900_000, unknown: ["a"])))
        #expect(text?.hasPrefix("Epoch 98: at least") == true)
    }

    @Test func everythingProvablyNotEarningShowsOnlyAPY() {
        let text = line(details(rewards: rewards(lamports: 0)))

        #expect(text?.contains("APY") == true)
        #expect(text?.contains("Last epoch") == false)
        #expect(text?.contains("unavailable") == false)
    }

    @Test func noPositionsNoLine() {
        #expect(line(details(rewards: nil, accounts: [])) == nil)
    }

    // MARK: Timing

    private func timed(slots: UInt64, duration: Double?, observedAt: Date) -> SolanaStakingDetails {
        var result = stored([])
        result.observedAt = observedAt
        result.slotDuration = duration
        result.slotsRemainingInEpoch = slots
        return result
    }

    @Test func nextEpochIsApproximateAndCountsDown() {
        let observed = stakingDate(0)
        let details = timed(slots: 100_000, duration: 0.2, observedAt: observed)

        let start = SolanaStakingModel.nextEpochText(details: details, now: observed)
        let later = SolanaStakingModel.nextEpochText(details: details, now: stakingDate(10_000))

        #expect(start?.hasPrefix("Next epoch in about") == true)
        #expect(start?.contains("5h") == true)
        #expect(later?.contains("2h") == true)
    }

    @Test func pastZeroItSaysEndingSoon() {
        let details = timed(slots: 10, duration: 0.2, observedAt: stakingDate(0))
        #expect(SolanaStakingModel.nextEpochText(details: details, now: stakingDate(60)) == "Epoch ending soon")
    }

    @Test func noMeasurementNoTime() {
        let details = timed(slots: 100, duration: nil, observedAt: stakingDate(0))
        #expect(SolanaStakingModel.nextEpochText(details: details, now: stakingDate(0)) == nil)
    }

    @Test func elapsedTimeIsTheFallbackMeasurement() {
        let read = SolanaStakingRead(
            accounts: [],
            clock: SolanaClock(epoch: 1, epochStartTimestamp: 1_000, slot: 432_000 + 10_000, unixTimestamp: 3_000),
            discovery: .complete,
            history: SolanaStakeHistory(entries: [:]),
            newRateEpoch: nil,
            schedule: SolanaEpochSchedule(firstNormalEpoch: 0, firstNormalSlot: 0, slotsPerEpoch: 432_000),
            slotDuration: nil
        )

        #expect(read.fallbackSlotDuration() == 0.2)
    }

    @Test func tooFewSlotsAreNotExtrapolated() {
        let read = SolanaStakingRead(
            accounts: [],
            clock: SolanaClock(epoch: 1, epochStartTimestamp: 1_000, slot: 432_000 + 10, unixTimestamp: 1_002),
            discovery: .complete,
            history: SolanaStakeHistory(entries: [:]),
            newRateEpoch: nil,
            schedule: SolanaEpochSchedule(firstNormalEpoch: 0, firstNormalSlot: 0, slotsPerEpoch: 432_000),
            slotDuration: nil
        )

        #expect(read.fallbackSlotDuration() == nil)
    }

    // MARK: Status text

    @Test func restrictedRowsSayWhy() {
        let clock = SolanaClock(epoch: 100, epochStartTimestamp: 0, slot: 0, unixTimestamp: 1_000)

        func text(_ account: SolanaStakeAccount, _ status: SolanaStakeStatus) -> String {
            SolanaStakingModel.statusText(
                SolanaStakePosition(account: account, activation: .init(), status: status),
                owner: solanaOwner,
                clock: clock
            )
        }

        #expect(text(stakeAccount("a"), .active) == "Active")
        #expect(text(stakeAccount("a"), .activating) == "Activating")
        #expect(text(stakeAccount("a", staker: solanaOtherWallet), .active) == "Can't unstake")
        #expect(text(stakeAccount("a", lockupTimestamp: 9_999), .active) == "Locked")
        #expect(text(stakeAccount("a", withdrawer: solanaOtherWallet), .active) == "Can't withdraw")
    }

    // MARK: Routing

    @Test func theLoaderServesSolanaOnly() async throws {
        let loader = try await setup().loader

        #expect(loader.supports(.solana(.devnet)))
        #expect(!loader.supports(.tron(.testnet)))
    }

    @Test func stakingStateServiceRoutesSolanaAccountsToItsLoader() async throws {
        let setup = try await setup()
        setup.source.update { $0.read = .success(solanaRead(accounts: [stakeAccount("a")])) }

        let service = StakingStateService(loaders: [setup.loader])
        try await service.refresh(setup.account)

        let details = try await storedSolanaDetails(setup.databaseService, setup.account)
        #expect(details.positions.map(\.account.address) == ["a"])
    }

    @Test func solanaSupportsTheStakingTab() {
        #expect(Blockchain.solana(.mainnet).supportsStaking)
        #expect(Blockchain.sui(.mainnet).supportsStaking)
        #expect(Blockchain.tron(.mainnet).supportsStaking)
        #expect(!Blockchain.bitcoin(.mainnet).supportsStaking)
    }
}
