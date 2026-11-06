// Live Stake 2.0 tests of `TronStakingService` on the Tron Nile testnet.
//
// Opt-in: they spend Nile TRX (fees and a small baseline stake) and run when
// `REEFR_TESTNET_MNEMONIC` is set — `Project.swift` forwards it into the test
// schemes from `TUIST_REEFR_TESTNET_MNEMONIC` at generation. The accounts are
// m/44'/195'/0'/0/0 and /1 ("Tron #1" and "Tron #2"); both need some Nile TRX.
// `TRONGRID_API_KEY` avoids TronGrid's anonymous rate limit.
//
// The write scenario is repeatable and net-zero on the stake: a baseline of
// 2 TRX stays staked (one-off setup), then each run votes, unstakes 1 TRX
// and cancels the unstake, so nothing is left waiting out the 14 days.
// Unstakes that earlier runs or other tools left behind and that have
// matured are withdrawn first.

import BigInt
import Foundation
import Testing
import WalletKit
@testable import ReefrWallet

@Suite(
    .serialized,
    .timeLimit(.minutes(10)),
    .enabled(if: ProcessInfo.processInfo.environment["REEFR_TESTNET_MNEMONIC"] != nil)
)

struct TronStakingNileTests {
    /// Gas for a handful of staking transactions, even if each burns TRX.
    static let gasReserve: UInt64 = 1_000_000
    /// Kept staked between runs, so one TRX can be unstaked and cancelled again.
    static let baselineStake: UInt64 = 2_000_000
    static let oneTRX: UInt64 = 1_000_000

    // MARK: Reads

    @Test(arguments: [0, 1])
    func readsTheStakingPositionAndRepresentatives(accountIndex: Int) async throws {
        let fixture = try await NileFixture.make(accountIndex: accountIndex)
        let state = try await fixture.service.state(for: fixture.account)

        // Every account gets a daily free bandwidth allowance.
        #expect(state.bandwidth.limit > 0)
        #expect(state.votePower == state.totalStaked / Self.oneTRX)
        #expect(state.assignedVotes <= state.votePower)

        let representatives = try await fixture.service.representatives(for: fixture.account)
        #expect(!representatives.isEmpty)
        #expect(representatives.map(\.voteCount) == representatives.map(\.voteCount).sorted(by: >))
    }

    @Test(arguments: [0, 1])
    func refusesInvalidActionsBeforeBuildingAnything(accountIndex: Int) async throws {
        let fixture = try await NileFixture.make(accountIndex: accountIndex)
        let state = try await fixture.service.state(for: fixture.account)
        let balance = try await fixture.service.availableBalance(for: fixture.account)
        let owner = try TronAddress(string: fixture.account.address)

        try await fixture.expect(.minimumStake, for: .stake(sun: Self.oneTRX - 1, resource: .energy))
        try await fixture.expect(.insufficientBalance, for: .stake(sun: balance + 1, resource: .bandwidth))
        try await fixture.expect(.unsupportedResource, for: .stake(sun: Self.oneTRX, resource: .tronPower))
        try await fixture.expect(.invalidAmount, for: .unstake(sun: 0, resource: .energy))
        try await fixture.expect(
            .insufficientStake,
            for: .unstake(sun: state.staked(for: .energy) + 1, resource: .energy)
        )

        try await fixture.expect(.noVotes, for: .vote([]))
        try await fixture.expect(
            .insufficientVotePower,
            for: .vote([.init(address: owner, count: state.votePower + 1)])
        )

        let tooMany = (0..<(TronStakingService.maxRepresentatives + 1)).map { _ in
            TronRawTransaction.Vote(address: owner, count: 1)
        }

        try await fixture.expect(.tooManyRepresentatives, for: .vote(tooMany))

        if state.withdrawable == 0 {
            try await fixture.expect(.noWithdrawable, for: .withdraw)
        }

        if state.unfrozen.isEmpty {
            try await fixture.expect(.noUnstaking, for: .cancelUnstaking)
        }

        if state.rewards == 0 {
            try await fixture.expect(.noRewards, for: .claim)
        }
    }

    // MARK: Writes

    /// Account #1 stakes Energy, account #2 Bandwidth: stake (once), vote, unstake, cancel.
    @Test(arguments: [0, 1])
    func stakesVotesUnstakesAndCancelsTheUnstake(accountIndex: Int) async throws {
        let resource: TronRawTransaction.Resource = accountIndex == 0 ? .energy : .bandwidth
        let fixture = try await NileFixture.make(accountIndex: accountIndex)
        let owner = try TronAddress(string: fixture.account.address)

        var state = try await fixture.state()

        // The first run also pays for the baseline stake; later ones only for gas.
        let balance = try await fixture.service.availableBalance(for: fixture.account)
        let needed = Self.gasReserve + (state.staked(for: resource) < Self.baselineStake ? Self.baselineStake : 0)
        try #require(
            balance >= needed,
            "\(owner.string) has \(balance) SUN on Nile; fund it with at least \(needed) SUN."
        )

        // 1. Collect unstakes that earlier runs left behind and that have matured.
        if state.withdrawable > 0 {
            try await fixture.perform(.withdraw)
            state = try await fixture.eventually("the matured unstakes are withdrawn") { $0.withdrawable == 0 }
        }

        // 2. A baseline stake, the first time only.
        if state.staked(for: resource) < Self.baselineStake {
            let missing = Self.baselineStake - state.staked(for: resource)
            let staked = state.staked(for: resource)

            try await fixture.perform(.stake(sun: max(missing, Self.oneTRX), resource: resource))
            state = try await fixture.eventually("the stake is counted") { $0.staked(for: resource) > staked }
        }

        #expect(state.staked(for: resource) >= Self.baselineStake)
        #expect(state.votePower >= 2)

        // 3. Vote with all the voting power for the most voted representative.
        let representative = try #require(try await fixture.service.representatives(for: fixture.account).first)
        let votes = [TronRawTransaction.Vote(address: representative.address, count: state.votePower)]

        try await fixture.perform(.vote(votes))
        state = try await fixture.eventually("the vote is counted") { $0.votes == votes }
        #expect(state.assignedVotes == state.votePower)

        // 4. Unstake 1 TRX: it leaves the stake and waits as a pending unstake.
        let beforeUnstake = state
        let pendingBefore = beforeUnstake.unfrozen.reduce(0) { $0 + $1.amount }

        try await fixture.perform(.unstake(sun: Self.oneTRX, resource: resource))
        state = try await fixture.eventually("the unstake is pending") {
            $0.unfrozen.reduce(0) { $0 + $1.amount } == pendingBefore + Self.oneTRX
        }

        #expect(state.staked(for: resource) == beforeUnstake.staked(for: resource) - Self.oneTRX)
        #expect(state.unfrozen.contains { $0.resource == resource && $0.amount == Self.oneTRX })
        // Votes the remaining power no longer covers are reduced by the network.
        #expect(state.assignedVotes <= state.votePower)

        // 5. Cancel: every pending unstake goes back to the stake.
        try await fixture.perform(.cancelUnstaking)
        state = try await fixture.eventually("the pending unstakes are cancelled") { $0.unfrozen.isEmpty }
        #expect(state.totalStaked == beforeUnstake.totalStaked + pendingBefore)
        #expect(state.staked(for: resource) >= Self.baselineStake)
    }

    /// Rewards accrue to voters every 6 hours and can be claimed once a day, so this only
    /// claims when there is something to claim, and stands down when the daily limit applies.
    @Test
    func claimsTheVotingRewardsWhenThereAreAny() async throws {
        let fixture = try await NileFixture.make(accountIndex: 0)
        let state = try await fixture.state()

        guard state.rewards > 0 else {
            return
        }

        do {
            try await fixture.perform(.claim)
        } catch {
            guard "\(error)".contains("24 hours") else {
                throw error
            }

            return
        }

        let after = try await fixture.eventually("the rewards are claimed") { $0.rewards < state.rewards }
        #expect(after.rewards < state.rewards)
    }
}

// MARK: - Fixture

/// A `.local` keystore of `REEFR_TESTNET_MNEMONIC` with its first Tron accounts on
/// Nile, driven through `TronStakingService` against the real network.
private struct NileFixture {
    let account: ReefrWallet.Account
    let service: TronStakingService

    static func make(accountIndex: Int) async throws -> NileFixture {
        let phrase = try #require(ProcessInfo.processInfo.environment["REEFR_TESTNET_MNEMONIC"])
        let mnemonic = try Mnemonic.fromPhrase(phrase)
        let databaseService = try makeDatabaseService()
        let accountService = AccountService(databaseService: databaseService)

        let keyStoreId = try await databaseService.insertKeyStore(KeyStore(
            deviceId: nil,
            kind: .local,
            name: "Nile Staking Test Key Store",
            mnemonicWordlist: mnemonic.wordlist,
            sealedEntropy: mnemonic.entropy,
            transport: nil,
            vendor: nil
        ))

        let keyStore = KeyStore(
            deviceId: nil,
            id: keyStoreId,
            kind: .local,
            name: "Nile Staking Test Key Store",
            mnemonicWordlist: mnemonic.wordlist,
            sealedEntropy: mnemonic.entropy,
            transport: nil,
            vendor: nil
        )

        // Each call takes the next unused index, so the last one is `accountIndex`.
        var account: ReefrWallet.Account?

        for _ in 0...accountIndex {
            account = try await accountService.makeAccount(.tron(.testnet), keyStore: keyStore)
        }

        let created = try #require(account)
        try #require(created.derivationPath?.string.hasSuffix("/\(accountIndex)") == true)

        let service = TronStakingService(
            balancesService: BalancesService(databaseService: databaseService),
            clientProvider: BlockchainClientProvider(),
            transactionService: TransactionService(databaseService: databaseService)
        )

        return NileFixture(account: created, service: service)
    }

    func state() async throws -> TronStakingState {
        try await service.state(for: account)
    }

    /// Prepares, signs and broadcasts `action`, then waits for the network to execute it.
    @discardableResult
    func perform(_ action: TronStakingAction) async throws -> TronStakingTransaction {
        let transaction = try await service.prepare(action, account: account)
        #expect(transaction.raw.contract == action.contract(owner: try TronAddress(string: account.address)))

        let signature = try await service.sign(transaction, account: account)
        let hash = try await service.broadcast(transaction, signature: signature, account: account)
        try await service.waitForConfirmation(hash, account: account)

        return transaction
    }

    /// Polls the position until `condition` holds (the node needs a block or two), for up to 45 s.
    func eventually(
        _ description: String,
        _ condition: (TronStakingState) -> Bool
    ) async throws -> TronStakingState {
        let deadline = ContinuousClock.now.advanced(by: .seconds(45))

        while true {
            let state = try await state()

            if condition(state) {
                return state
            }

            guard ContinuousClock.now < deadline else {
                throw NileTestError(description: "Nile didn't show \(description) within 45 seconds.")
            }

            try await Task.sleep(for: .seconds(3))
        }
    }

    /// `action` must be refused with `error` by validation, before anything is built.
    func expect(_ error: TronStakingError, for action: TronStakingAction) async throws {
        await #expect(throws: error) {
            _ = try await service.prepare(action, account: account)
        }
    }
}

private struct NileTestError: Swift.Error, CustomStringConvertible {
    let description: String
}
