// Unit tests for TronStakingService's action validation: what the staking
// sheets may ask the node to build, given the account's live position.

import Foundation
import Testing
import WalletKit
@testable import ReefrWallet

private let now = Date(timeIntervalSince1970: 1_762_500_000)

private func address(_ byte: UInt8) throws -> TronAddress {
    try TronAddress(rawBytes: Data([0x41]) + Data(repeating: byte, count: 20))
}

private func vote(_ byte: UInt8, _ count: UInt64) throws -> TronRawTransaction.Vote {
    TronRawTransaction.Vote(address: try address(byte), count: count)
}

/// 130 TRX staked for bandwidth and 240 for energy (370 votes).
private func state(
    rewards: UInt64 = 685_004,
    withdrawable: UInt64 = 30_000_000,
    unfrozen: [TronStakingState.Unfrozen] = []
) -> TronStakingState {
    TronStakingState(
        bandwidth: .init(limit: 810, remaining: 810),
        energy: .init(limit: 2_316, remaining: 2_316),
        frozen: [
            .init(amount: 130_000_000, resource: .bandwidth),
            .init(amount: 240_000_000, resource: .energy)
        ],
        rewards: rewards,
        unfrozen: unfrozen,
        votes: [],
        weights: .init(
            energyLimit: 180_000_000_000,
            energyWeight: 10_000_000_000,
            netLimit: 43_200_000_000,
            netWeight: 9_000_000_000
        ),
        withdrawable: withdrawable
    )
}

private func pending(_ count: Int) -> [TronStakingState.Unfrozen] {
    (0..<count).map { index in
        .init(amount: 1_000_000, expiration: now.addingTimeInterval(TimeInterval(1_000 + index)), resource: .energy)
    }
}

@Suite(.timeLimit(.minutes(1)))
struct TronStakingServiceTests {
    private func validate(
        _ action: TronStakingAction,
        state: TronStakingState = state(),
        balance: UInt64 = 938_295_311
    ) throws {
        try TronStakingService.validate(action, state: state, balance: balance, now: now)
    }

    // MARK: Stake

    @Test func stakesWithinTheBalance() throws {
        try validate(.stake(sun: 100_000_000, resource: .energy))
        try validate(.stake(sun: 938_295_311, resource: .bandwidth))
    }

    @Test func refusesToStakeLessThanOneTRX() {
        #expect(throws: TronStakingError.minimumStake) { try validate(.stake(sun: 999_999, resource: .energy)) }
    }

    @Test func refusesToStakeMoreThanTheBalance() {
        #expect(throws: TronStakingError.insufficientBalance) {
            try validate(.stake(sun: 938_295_312, resource: .energy))
        }
    }

    @Test func refusesToStakeForTronPower() {
        #expect(throws: TronStakingError.unsupportedResource) {
            try validate(.stake(sun: 10_000_000, resource: .tronPower))
        }
    }

    // MARK: Unstake

    @Test func unstakesUpToWhatIsStakedForTheResource() throws {
        try validate(.unstake(sun: 240_000_000, resource: .energy))

        #expect(throws: TronStakingError.insufficientStake) {
            try validate(.unstake(sun: 240_000_001, resource: .energy))
        }

        #expect(throws: TronStakingError.insufficientStake) {
            try validate(.unstake(sun: 130_000_001, resource: .bandwidth))
        }
    }

    @Test func refusesAnEmptyUnstake() {
        #expect(throws: TronStakingError.invalidAmount) { try validate(.unstake(sun: 0, resource: .energy)) }
    }

    @Test func limitsPendingUnstakesButIgnoresFinishedOnes() throws {
        try validate(.unstake(sun: 1_000_000, resource: .energy), state: state(unfrozen: pending(31)))

        #expect(throws: TronStakingError.tooManyUnstakes) {
            try validate(.unstake(sun: 1_000_000, resource: .energy), state: state(unfrozen: pending(32)))
        }

        // 32 entries, but one has already passed its 14 days: only 31 are waiting.
        var entries = pending(31)
        entries.append(.init(amount: 1_000_000, expiration: now.addingTimeInterval(-1), resource: .bandwidth))
        try validate(.unstake(sun: 1_000_000, resource: .energy), state: state(unfrozen: entries))
    }

    // MARK: Vote

    @Test func votesUpToTheStakedTRX() throws {
        try validate(.vote([vote(1, 250), vote(2, 120)]))

        #expect(throws: TronStakingError.insufficientVotePower) { try validate(.vote([vote(1, 371)])) }
        #expect(throws: TronStakingError.insufficientVotePower) { try validate(.vote([vote(1, 300), vote(2, 71)])) }
    }

    @Test func votesForAtMostNineDistinctRepresentatives() throws {
        try validate(.vote((1...9).map { try vote(UInt8($0), 10) }))

        #expect(throws: TronStakingError.tooManyRepresentatives) {
            try validate(.vote((1...10).map { try vote(UInt8($0), 10) }))
        }

        #expect(throws: TronStakingError.duplicateRepresentative) { try validate(.vote([vote(1, 10), vote(1, 20)])) }
    }

    /// Vote counts come from text fields: a sum that overflows must be refused, not trap.
    @Test func refusesVotesWhoseSumOverflows() throws {
        #expect(throws: TronStakingError.insufficientVotePower) {
            try validate(.vote([vote(1, UInt64(Int64.max)), vote(2, UInt64(Int64.max)), vote(3, 5)]))
        }

        #expect(throws: TronStakingError.insufficientVotePower) {
            try validate(.vote([vote(1, .max), vote(2, 1)]))
        }
    }

    @Test func refusesEmptyVotes() throws {
        #expect(throws: TronStakingError.noVotes) { try validate(.vote([])) }
        #expect(throws: TronStakingError.invalidAmount) { try validate(.vote([vote(1, 0)])) }
    }

    @Test func cannotVoteWithoutAStake() throws {
        let unstaked = TronStakingState(
            bandwidth: .init(limit: 600, remaining: 600),
            energy: .init(limit: 0, remaining: 0),
            frozen: [],
            rewards: 0,
            unfrozen: [],
            votes: [],
            weights: .init(energyLimit: 0, energyWeight: 0, netLimit: 0, netWeight: 0),
            withdrawable: 0
        )

        #expect(throws: TronStakingError.insufficientVotePower) { try validate(.vote([vote(1, 1)]), state: unstaked) }
    }

    // MARK: Claim, withdraw, cancel

    @Test func claimsOnlyWhenThereAreRewards() throws {
        try validate(.claim)
        #expect(throws: TronStakingError.noRewards) { try validate(.claim, state: state(rewards: 0)) }
    }

    @Test func withdrawsOnlyWhenSomethingIsReady() throws {
        try validate(.withdraw)
        #expect(throws: TronStakingError.noWithdrawable) { try validate(.withdraw, state: state(withdrawable: 0)) }
    }

    @Test func cancelsOnlyWhenSomethingIsPending() throws {
        try validate(.cancelUnstaking, state: state(unfrozen: pending(1)))
        #expect(throws: TronStakingError.noUnstaking) { try validate(.cancelUnstaking) }
    }

    // MARK: Contracts

    @Test func mapsEachActionToItsContract() throws {
        let owner = try address(9)
        let votes = [try vote(1, 5)]

        #expect(TronStakingAction.stake(sun: 5, resource: .energy).contract(owner: owner)
            == .freezeBalanceV2(owner: owner, amount: 5, resource: .energy))
        #expect(TronStakingAction.unstake(sun: 5, resource: .bandwidth).contract(owner: owner)
            == .unfreezeBalanceV2(owner: owner, amount: 5, resource: .bandwidth))
        #expect(TronStakingAction.vote(votes).contract(owner: owner) == .voteWitness(owner: owner, votes: votes))
        #expect(TronStakingAction.claim.contract(owner: owner) == .withdrawBalance(owner: owner))
        #expect(TronStakingAction.withdraw.contract(owner: owner) == .withdrawExpireUnfreeze(owner: owner))
        #expect(TronStakingAction.cancelUnstaking.contract(owner: owner) == .cancelAllUnfreezeV2(owner: owner))
    }
}
