// Tests of StakingStateService and the Tron loader behind it: what is stored, how overlapping
// reads are shared or ordered, and how representative lookups (best effort, cached per network) behave.

import Foundation
import Testing
import WalletKit
@testable import ReefrWallet

@Suite(.timeLimit(.minutes(1)))
struct StakingStateServiceTests {
    private struct Failure: Error {}

    private let validator = stakingAddress(1)

    private var votes: [TronRawTransaction.Vote] {
        [TronRawTransaction.Vote(address: validator, count: 100)]
    }

    private func representative(name: String? = "P2P", apr: Decimal? = 3.5) -> TronRepresentative {
        TronRepresentative(address: validator, apr: apr, name: name, voteCount: 1_000)
    }

    private struct Fixture {
        let account: ReefrWallet.Account
        let clock: SteppingClock
        let databaseService: DatabaseService
        let loader: TronStakingPositionLoader
        let service: StakingStateService
        let source: ControlledTronStakingSource

        func staking() async throws -> Staking? {
            try await databaseService.fetchStaking(accountId: try idOf(account))
        }

        func details() async throws -> TronStakingDetails {
            guard case let .tron(details)? = try await staking()?.details else {
                throw Failure()
            }

            return details
        }
    }

    private func makeFixture(blockchain: Blockchain = .tron(.testnet)) async throws -> Fixture {
        let databaseService = try makeDatabaseService()
        let account = try await makeStakingAccount(databaseService, blockchain: blockchain)
        let clock = SteppingClock()
        let source = ControlledTronStakingSource()

        let loader = TronStakingPositionLoader(databaseService: databaseService, source: source, now: { clock.now() })

        return Fixture(
            account: account,
            clock: clock,
            databaseService: databaseService,
            loader: loader,
            service: StakingStateService(loaders: [loader]),
            source: source
        )
    }

    // MARK: Refresh

    @Test func refreshStoresThePositionWithVotedRepresentatives() async throws {
        let fixture = try await makeFixture()
        fixture.source.answer(with: stakingPosition(rewards: 12, votes: votes))
        fixture.source.setRepresentatives(.success([
            representative(),
            TronRepresentative(address: stakingAddress(9), voteCount: 1)
        ]))

        try await fixture.service.refresh(fixture.account)

        let staking = try #require(try await fixture.staking())
        let details = try await fixture.details()

        #expect(staking.staked == 300_000_000)
        #expect(staking.rewards == 12)
        #expect(staking.apr == 3.5)
        #expect(details.representatives.keys.sorted() == [validator.string])
        #expect(details.representatives[validator.string]?.name == "P2P")
    }

    @Test func refreshStoresAnUnstakedAccountToo() async throws {
        let fixture = try await makeFixture()

        fixture.source.answer(with: TronStakingState(
            bandwidth: .init(limit: 600, remaining: 600),
            energy: .init(limit: 0, remaining: 0),
            frozen: [],
            rewards: 0,
            unfrozen: [],
            votes: [],
            weights: .init(energyLimit: 0, energyWeight: 0, netLimit: 0, netWeight: 0),
            withdrawable: 0
        ))

        try await fixture.service.refresh(fixture.account)

        let staking = try #require(try await fixture.staking())
        #expect(staking.staked == 0)
        #expect(staking.apr == nil)
    }

    @Test func refreshIgnoresChainsWithoutStaking() async throws {
        let fixture = try await makeFixture(blockchain: .evm(.custom(31_337)))

        try await fixture.service.refresh(fixture.account)
        try await fixture.service.refreshAfterChange(fixture.account)

        #expect(fixture.source.stateRequests == 0)
        #expect(try storedStakingRows(fixture.databaseService).isEmpty)
    }

    @Test func refreshThrowsAndStoresNothingWhenThePositionCannotBeRead() async throws {
        let fixture = try await makeFixture()

        let refresh = Task { try await fixture.service.refresh(fixture.account) }
        try await eventually { fixture.source.pendingStateReads == 1 }
        fixture.source.fail(0, with: Failure())

        await #expect(throws: Failure.self) { try await refresh.value }
        #expect(try await fixture.staking() == nil)
    }

    // MARK: Loaders

    @Test func routesAnAccountToTheLoaderThatSupportsItsChain() async throws {
        let fixture = try await makeFixture()
        let other = RecordingPositionLoader { !fixture.loader.supports($0) }
        let tron = RecordingPositionLoader { fixture.loader.supports($0) }
        let service = StakingStateService(loaders: [other, tron])

        try await service.refresh(fixture.account)
        try await service.refreshAfterChange(fixture.account)

        #expect(await tron.accounts == [fixture.account.address, fixture.account.address])
        #expect(await other.accounts.isEmpty)
    }

    @Test func ignoresChainsNoLoaderSupports() async throws {
        let fixture = try await makeFixture()
        let loader = RecordingPositionLoader { _ in false }

        try await StakingStateService(loaders: [loader]).refresh(fixture.account)

        #expect(await loader.accounts.isEmpty)
    }

    // MARK: Coalescing

    @Test func concurrentRefreshesShareOneRead() async throws {
        let fixture = try await makeFixture()

        async let first: Void = fixture.service.refresh(fixture.account)
        try await eventually { fixture.source.pendingStateReads == 1 }

        async let second: Void = fixture.service.refresh(fixture.account)
        try await Task.sleep(for: .milliseconds(50))
        #expect(fixture.source.stateRequests == 1)

        fixture.source.complete(0, with: stakingPosition(rewards: 3))
        try await first
        try await second

        #expect(fixture.source.stateRequests == 1)
        #expect(try await fixture.staking()?.rewards == 3)

        // Once done, the next refresh reads again.
        fixture.source.answer(with: stakingPosition(rewards: 4))
        try await fixture.service.refresh(fixture.account)
        #expect(try await fixture.staking()?.rewards == 4)
    }

    @Test func refreshAfterChangeReadsAgainAfterTheReadInFlight() async throws {
        let fixture = try await makeFixture()

        async let inFlight: Void = fixture.service.refresh(fixture.account)
        try await eventually { fixture.source.pendingStateReads == 1 }

        async let afterChange: Void = fixture.service.refreshAfterChange(fixture.account)
        try await Task.sleep(for: .milliseconds(50))
        #expect(fixture.source.stateRequests == 1)

        // The read that began before the change finishes with the old position…
        fixture.source.complete(0, with: stakingPosition(rewards: 1))
        try await inFlight

        // …and the follow-up reads the new one.
        try await eventually { fixture.source.pendingStateReads == 1 }
        fixture.source.complete(0, with: stakingPosition(rewards: 2))
        try await afterChange

        #expect(fixture.source.stateRequests == 2)
        #expect(try await fixture.staking()?.rewards == 2)
    }

    @Test func concurrentChangesShareOneFollowUp() async throws {
        let fixture = try await makeFixture()

        async let inFlight: Void = fixture.service.refresh(fixture.account)
        try await eventually { fixture.source.pendingStateReads == 1 }

        async let first: Void = fixture.service.refreshAfterChange(fixture.account)
        try await Task.sleep(for: .milliseconds(50))
        async let second: Void = fixture.service.refreshAfterChange(fixture.account)
        try await Task.sleep(for: .milliseconds(50))

        fixture.source.complete(0, with: stakingPosition(rewards: 1))
        try await inFlight
        try await eventually { fixture.source.pendingStateReads == 1 }
        fixture.source.complete(0, with: stakingPosition(rewards: 2))
        try await first
        try await second

        #expect(fixture.source.stateRequests == 2)
    }

    // MARK: Out-of-order observations

    @Test func aPositionRecordedMeanwhileBeatsAnOlderRefresh() async throws {
        let fixture = try await makeFixture()

        async let refresh: Void = fixture.service.refresh(fixture.account)
        try await eventually { fixture.source.pendingStateReads == 1 }

        // A newer read elsewhere (say a staking sheet's) lands first…
        await fixture.loader.record(
            state: stakingPosition(rewards: 9),
            startedAt: fixture.clock.now(),
            account: fixture.account
        )

        // …then the refresh that began earlier finishes with a stale answer.
        fixture.source.complete(0, with: stakingPosition(rewards: 1))
        try await refresh

        #expect(try await fixture.staking()?.rewards == 9)
        #expect(try await fixture.staking()?.revision == 1)
    }

    @Test func allowancesRecordedMeanwhileSurviveAnOlderRefresh() async throws {
        let fixture = try await makeFixture()
        fixture.source.answer(with: stakingPosition(bandwidth: 600))
        try await fixture.service.refresh(fixture.account)
        fixture.source.answer(with: nil)

        async let refresh: Void = fixture.service.refresh(fixture.account)
        try await eventually { fixture.source.pendingStateReads == 1 }

        await fixture.loader.record(
            resources: resources(bandwidth: 50, energy: 50),
            startedAt: fixture.clock.now(),
            account: fixture.account
        )

        fixture.source.complete(0, with: stakingPosition(rewards: 77, bandwidth: 400))
        try await refresh

        let staking = try #require(try await fixture.staking())
        let details = try await fixture.details()

        #expect(staking.rewards == 77)
        #expect(details.state.bandwidth.remaining == 50)
        #expect(details.state.energy.remaining == 50)
    }

    @Test func recordingAllowancesNeedsAPosition() async throws {
        let fixture = try await makeFixture()

        await fixture.loader.record(
            resources: resources(bandwidth: 1, energy: 1),
            startedAt: fixture.clock.now(),
            account: fixture.account
        )

        #expect(try await fixture.staking() == nil)
    }

    // MARK: Representatives

    @Test func storesThePositionWhenRepresentativesCannotBeLoaded() async throws {
        let fixture = try await makeFixture()
        fixture.source.answer(with: stakingPosition(rewards: 5, votes: votes))
        fixture.source.setRepresentatives(.failure(Failure()))

        try await fixture.service.refresh(fixture.account)

        let staking = try #require(try await fixture.staking())
        #expect(staking.rewards == 5)
        #expect(staking.apr == nil)
        #expect(try await fixture.details().representatives.isEmpty)
    }

    @Test func keepsStoredNamesWhenALaterLookupFailsOrFallsBack() async throws {
        let fixture = try await makeFixture()
        fixture.source.answer(with: stakingPosition(votes: votes))
        fixture.source.setRepresentatives(.success([representative()]))
        try await fixture.service.refresh(fixture.account)

        // An hour on, TronScan is down…
        fixture.clock.jump(by: 4_000)
        fixture.source.setRepresentatives(.failure(Failure()))
        try await fixture.service.refresh(fixture.account)
        #expect(try await fixture.details().representatives[validator.string]?.name == "P2P")

        // …or the node's list, with no names or rates, is all there is.
        fixture.clock.jump(by: 4_000)
        fixture.source.setRepresentatives(.success([representative(name: nil, apr: nil)]))
        try await fixture.service.refresh(fixture.account)

        let staking = try #require(try await fixture.staking())
        #expect(try await fixture.details().representatives[validator.string]?.name == "P2P")
        #expect(staking.apr == 3.5)
    }

    @Test func cachesRepresentativesUntilTheyExpire() async throws {
        let fixture = try await makeFixture()
        fixture.source.answer(with: stakingPosition(votes: votes))
        fixture.source.setRepresentatives(.success([representative()]))

        try await fixture.service.refresh(fixture.account)
        try await fixture.service.refresh(fixture.account)
        #expect(fixture.source.representativeRequests == 1)

        fixture.clock.jump(by: 4_000)
        try await fixture.service.refresh(fixture.account)
        #expect(fixture.source.representativeRequests == 2)
    }

    @Test func looksAgainSoonAfterAListWithoutNames() async throws {
        let fixture = try await makeFixture()
        fixture.source.answer(with: stakingPosition(votes: votes))
        fixture.source.setRepresentatives(.success([representative(name: nil, apr: nil)]))

        try await fixture.service.refresh(fixture.account)
        fixture.clock.jump(by: 120)
        fixture.source.setRepresentatives(.success([representative()]))
        try await fixture.service.refresh(fixture.account)

        #expect(fixture.source.representativeRequests == 2)
        #expect(try await fixture.details().representatives[validator.string]?.name == "P2P")
    }

    @Test func doesNotShareRepresentativesAcrossNetworksOrEndpoints() async throws {
        let fixture = try await makeFixture()
        let mainnet = try await makeStakingAccount(
            fixture.databaseService,
            blockchain: .tron(.mainnet),
            address: "TMVQGm1qAQYVdetCeGRRkTWYYrLXuHK2HC"
        )

        let custom = try await makeStakingAccount(
            fixture.databaseService,
            address: "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t",
            rpcURL: URL(string: "https://node.example.com")
        )

        fixture.source.answer(with: stakingPosition())

        for account in [fixture.account, mainnet, custom, fixture.account, mainnet, custom] {
            try await fixture.service.refresh(account)
        }

        #expect(fixture.source.representativeRequests == 3)
    }
}
