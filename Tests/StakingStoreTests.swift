// Tests of the stored staking position: persistence, the 1-to-1 relation and the
// rules that keep an older observation from overwriting a newer one.

import BigInt
import Foundation
import SwiftData
import Testing
import WalletKit
@testable import ReefrWallet

@Suite(.timeLimit(.minutes(1)))
struct StakingStoreTests {
    private let validator = stakingAddress(1)

    private func vote(_ count: UInt64 = 100) -> [TronRawTransaction.Vote] {
        [TronRawTransaction.Vote(address: validator, count: count)]
    }

    private func named(_ name: String?, apr: Decimal?) -> [String: TronStakingDetails.Representative] {
        [validator.string: .init(name: name, apr: apr)]
    }

    @discardableResult
    private func saved(
        _ databaseService: DatabaseService,
        _ account: ReefrWallet.Account,
        _ state: TronStakingState = stakingPosition(),
        representatives: [String: TronStakingDetails.Representative] = [:],
        at seconds: TimeInterval
    ) async throws -> Bool {
        try await databaseService.saveStakingState(
            accountId: try idOf(account),
            state: state,
            representatives: representatives,
            startedAt: stakingDate(seconds)
        )
    }

    private func fetched(_ databaseService: DatabaseService, _ account: ReefrWallet.Account) async throws -> Staking {
        try #require(try await databaseService.fetchStaking(accountId: try idOf(account)))
    }

    private func tronDetails(_ staking: Staking) throws -> TronStakingDetails {
        guard case let .tron(details) = staking.details else {
            throw ReefrError.invalidData
        }

        return details
    }

    // MARK: Persistence

    @Test func storesThePositionOnTheNativeToken() async throws {
        let databaseService = try makeDatabaseService()
        let account = try await makeStakingAccount(databaseService)
        let state = stakingPosition(rewards: 685_004, votes: vote())

        #expect(try await databaseService.fetchStaking(accountId: try idOf(account)) == nil)
        #expect(try await saved(databaseService, account, state, representatives: named("P2P", apr: 3.27), at: 1))

        let staking = try await fetched(databaseService, account)
        let details = try tronDetails(staking)

        #expect(staking.staked == 300_000_000)
        #expect(staking.rewards == 685_004)
        #expect(staking.apr == 3.27)
        #expect(staking.revision == 1)
        #expect(details.state == state)
        #expect(details.representatives[validator.string]?.name == "P2P")

        let tokens = try ModelContext(databaseService.modelContainer).fetch(FetchDescriptor<TokenModel>())
        let native = try #require(tokens.first { $0.isNativeToken && $0.symbol == "TRX" })
        #expect(staking.tokenId == native.persistentModelID)
    }

    @Test func keepsOneRowPerAccount() async throws {
        let databaseService = try makeDatabaseService()
        let account = try await makeStakingAccount(databaseService)
        let other = try await makeStakingAccount(databaseService, address: "TMVQGm1qAQYVdetCeGRRkTWYYrLXuHK2HC")

        try await saved(databaseService, account, at: 1)
        try await saved(databaseService, account, stakingPosition(rewards: 9), at: 2)
        try await saved(databaseService, other, at: 1)

        #expect(try storedStakingRows(databaseService).count == 2)
        #expect(try await fetched(databaseService, account).rewards == 9)
        #expect(try await fetched(databaseService, account).revision == 2)
        #expect(try await fetched(databaseService, other).revision == 1)
    }

    @Test func isDeletedWithItsAccount() async throws {
        let databaseService = try makeDatabaseService()
        let account = try await makeStakingAccount(databaseService)
        try await saved(databaseService, account, at: 1)

        try await databaseService.deleteAccount(id: try idOf(account))

        #expect(try storedStakingRows(databaseService).isEmpty)
    }

    @Test func readsAnUndecodablePositionAsMissingAndReplacesIt() async throws {
        let databaseService = try makeDatabaseService()
        let account = try await makeStakingAccount(databaseService)
        try await saved(databaseService, account, at: 1)

        let context = ModelContext(databaseService.modelContainer)
        try #require(context.fetch(FetchDescriptor<StakingModel>()).first).serializedDetails = Data("nope".utf8)
        try context.save()

        #expect(try await databaseService.fetchStaking(accountId: try idOf(account)) == nil)

        // Even an older read replaces what can't be read.
        #expect(try await saved(databaseService, account, stakingPosition(rewards: 7), at: 0))
        #expect(try await fetched(databaseService, account).rewards == 7)
        #expect(try storedStakingRows(databaseService).count == 1)
    }

    // MARK: Resources

    @Test func resourcePatchNeedsAnExistingPosition() async throws {
        let databaseService = try makeDatabaseService()
        let account = try await makeStakingAccount(databaseService)
        let accountId = try idOf(account)

        let applied = try await databaseService.saveStakingResources(
            accountId: accountId,
            resources: resources(bandwidth: 1, energy: 1),
            startedAt: stakingDate(1)
        )

        #expect(!applied)
        #expect(try await databaseService.fetchStaking(accountId: accountId) == nil)
        #expect(try storedStakingRows(databaseService).isEmpty)
    }

    @Test func resourcePatchChangesOnlyAllowances() async throws {
        let databaseService = try makeDatabaseService()
        let account = try await makeStakingAccount(databaseService)
        let accountId = try idOf(account)
        try await saved(databaseService, account, stakingPosition(votes: vote()), at: 1)

        #expect(try await databaseService.saveStakingResources(
            accountId: accountId,
            resources: resources(bandwidth: 10, energy: 20),
            startedAt: stakingDate(2)
        ))

        let staking = try await fetched(databaseService, account)
        let state = try tronDetails(staking).state

        #expect(state.bandwidth.remaining == 10)
        #expect(state.energy.remaining == 20)
        #expect(state.votes == vote())
        #expect(staking.revision == 2)
        #expect(staking.stateObservedAt == stakingDate(1))
        #expect(staking.resourcesObservedAt == stakingDate(2))
    }

    // MARK: Ordering

    @Test func discardsAnOlderPositionAfterANewerOne() async throws {
        let databaseService = try makeDatabaseService()
        let account = try await makeStakingAccount(databaseService)
        try await saved(databaseService, account, stakingPosition(rewards: 2), at: 20)

        #expect(try await !saved(databaseService, account, stakingPosition(rewards: 1), at: 10))

        let staking = try await fetched(databaseService, account)
        #expect(staking.rewards == 2)
        #expect(staking.revision == 1)
    }

    @Test func discardsTiedObservations() async throws {
        let databaseService = try makeDatabaseService()
        let account = try await makeStakingAccount(databaseService)
        let accountId = try idOf(account)
        try await saved(databaseService, account, stakingPosition(rewards: 2), at: 10)

        #expect(try await !saved(databaseService, account, stakingPosition(rewards: 3), at: 10))
        #expect(try await !databaseService.saveStakingResources(
            accountId: accountId,
            resources: resources(bandwidth: 1, energy: 1),
            startedAt: stakingDate(10)
        ))

        #expect(try await fetched(databaseService, account).rewards == 2)
        #expect(try await fetched(databaseService, account).revision == 1)
    }

    @Test func keepsNewerResourcesWhenAnOlderPositionArrivesLater() async throws {
        let databaseService = try makeDatabaseService()
        let account = try await makeStakingAccount(databaseService)
        let accountId = try idOf(account)
        try await saved(databaseService, account, stakingPosition(rewards: 1, bandwidth: 600), at: 10)

        // A fee read at 30 sees 100 bandwidth left; a position read that started at 20 finishes after it.
        try await databaseService.saveStakingResources(
            accountId: accountId,
            resources: resources(bandwidth: 100, energy: 100),
            startedAt: stakingDate(30)
        )

        #expect(try await saved(databaseService, account, stakingPosition(rewards: 5, bandwidth: 400), at: 20))

        let staking = try await fetched(databaseService, account)
        let state = try tronDetails(staking).state

        #expect(staking.rewards == 5)
        #expect(state.bandwidth.remaining == 100)
        #expect(state.energy.remaining == 100)
        #expect(staking.stateObservedAt == stakingDate(20))
        #expect(staking.resourcesObservedAt == stakingDate(30))
    }

    @Test func takesNewerResourcesFromANewerPosition() async throws {
        let databaseService = try makeDatabaseService()
        let account = try await makeStakingAccount(databaseService)
        try await saved(databaseService, account, stakingPosition(bandwidth: 600), at: 10)

        try await saved(databaseService, account, stakingPosition(bandwidth: 300), at: 20)

        let staking = try await fetched(databaseService, account)
        #expect(try tronDetails(staking).state.bandwidth.remaining == 300)
        #expect(staking.resourcesObservedAt == stakingDate(20))
    }

    @Test func discardsAnOlderResourcePatchAfterANewerPosition() async throws {
        let databaseService = try makeDatabaseService()
        let account = try await makeStakingAccount(databaseService)
        try await saved(databaseService, account, stakingPosition(bandwidth: 300), at: 20)

        let applied = try await databaseService.saveStakingResources(
            accountId: try idOf(account),
            resources: resources(bandwidth: 600, energy: 600),
            startedAt: stakingDate(10)
        )

        #expect(!applied)
        #expect(try tronDetails(try await fetched(databaseService, account)).state.bandwidth.remaining == 300)
        #expect(try await fetched(databaseService, account).revision == 1)
    }

    // MARK: Representative metadata

    @Test func keepsKnownNamesAndRatesWhenALaterReadHasNone() async throws {
        let databaseService = try makeDatabaseService()
        let account = try await makeStakingAccount(databaseService)
        let state = stakingPosition(votes: vote())

        try await saved(databaseService, account, state, representatives: named("P2P", apr: 3.27), at: 1)
        // A failed lookup, then the node's fallback list (neither names nor rates).
        try await saved(databaseService, account, state, at: 2)
        try await saved(databaseService, account, state, representatives: named(nil, apr: nil), at: 3)

        let staking = try await fetched(databaseService, account)
        #expect(try tronDetails(staking).representatives[validator.string]?.name == "P2P")
        #expect(staking.apr == 3.27)
        #expect(staking.revision == 3)
    }

    @Test func updatesRatesAndDropsRepresentativesNoLongerVotedFor() async throws {
        let databaseService = try makeDatabaseService()
        let account = try await makeStakingAccount(databaseService)
        let other = stakingAddress(2)

        let both = [
            TronRawTransaction.Vote(address: validator, count: 100),
            TronRawTransaction.Vote(address: other, count: 300)
        ]

        try await saved(
            databaseService,
            account,
            stakingPosition(votes: both),
            representatives: [
                validator.string: .init(name: "A", apr: 4),
                other.string: .init(name: "B", apr: 2)
            ],
            at: 1
        )

        // Weighted by votes: (4 × 100 + 2 × 300) / 400.
        #expect(try await fetched(databaseService, account).apr == 2.5)

        try await saved(
            databaseService,
            account,
            stakingPosition(votes: vote()),
            representatives: named(nil, apr: 5),
            at: 2
        )

        let staking = try await fetched(databaseService, account)
        let details = try tronDetails(staking)

        #expect(details.representatives.keys.sorted() == [validator.string])
        #expect(details.representatives[validator.string]?.name == "A")
        #expect(staking.apr == 5)
    }

    @Test func hasNoRateUnlessEveryVotedRepresentativeHasOne() async throws {
        let databaseService = try makeDatabaseService()
        let account = try await makeStakingAccount(databaseService)
        let other = stakingAddress(2)

        let both = [
            TronRawTransaction.Vote(address: validator, count: 100),
            TronRawTransaction.Vote(address: other, count: 100)
        ]

        try await saved(
            databaseService,
            account,
            stakingPosition(votes: both),
            representatives: named("A", apr: 4),
            at: 1
        )

        #expect(try await fetched(databaseService, account).apr == nil)
        #expect(try await saved(databaseService, account, stakingPosition(), at: 2))
        #expect(try await fetched(databaseService, account).apr == nil)
    }
}
