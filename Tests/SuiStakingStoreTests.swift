// How a Sui position is stored: what a read replaces, what it keeps, and the one-at-a-time claim.

import Foundation
import SwiftData
import Testing
import WalletKit
@testable import ReefrWallet

@Suite(.timeLimit(.minutes(1)))
struct SuiStakingStoreTests {
    private func setUp() async throws -> (database: DatabaseService, accountId: PersistentIdentifier) {
        let database = try makeDatabaseService()
        let account = try await makeSuiStakingAccount(database)
        return (database, try idOf(account))
    }

    private func details(
        _ database: DatabaseService, _ accountId: PersistentIdentifier
    ) async throws -> SuiStakingDetails {
        guard case let .sui(details)? = try await database.fetchStaking(accountId: accountId)?.details else {
            throw ReefrError.notFound
        }

        return details
    }

    @Test func aFirstReadCreatesThePositionWithItsTotals() async throws {
        let (database, accountId) = try await setUp()
        let positions = [
            suiPosition(suiStakedSui(principal: 10_000_000_000, byte: 0xB1), reward: 1_000_000),
            suiPosition(suiStakedSui(principal: 5_000_000_000, byte: 0xB2), reward: 2_000_000)
        ]

        let applied = try await database.saveStakingState(
            accountId: accountId, read: suiRead(positions: positions), startedAt: stakingDate(1)
        )

        #expect(applied)
        let stored = try #require(try await database.fetchStaking(accountId: accountId))
        #expect(stored.staked == 15_000_000_000)
        #expect(stored.rewards == 3_000_000)
        #expect(stored.apr == nil)
        #expect(try await details(database, accountId).isRewardsComplete)
    }

    @Test func anUnknownRewardKeepsTheKnownOnesAndSaysSo() async throws {
        let (database, accountId) = try await setUp()
        let positions = [
            suiPosition(suiStakedSui(byte: 0xB1), reward: 1_000_000),
            suiPosition(suiStakedSui(byte: 0xB2), reward: nil)
        ]

        try await database.saveStakingState(
            accountId: accountId, read: suiRead(positions: positions), startedAt: stakingDate(1)
        )

        let stored = try await details(database, accountId)
        #expect(stored.estimatedRewardsMist == 1_000_000)
        #expect(!stored.isRewardsComplete)
    }

    @Test func pendingAndRetiredStakeStillCountAsStaked() async throws {
        let (database, accountId) = try await setUp()
        let positions = [
            suiPosition(suiStakedSui(principal: 1_000_000_000, byte: 0xB1), status: .pending, reward: 0),
            suiPosition(suiStakedSui(principal: 2_000_000_000, byte: 0xB2), status: .retired, reward: 0)
        ]

        try await database.saveStakingState(
            accountId: accountId, read: suiRead(positions: positions), startedAt: stakingDate(1)
        )

        #expect(try #require(try await database.fetchStaking(accountId: accountId)).staked == 3_000_000_000)
    }

    @Test func anOlderReadNeverUndoesANewerOne() async throws {
        let (database, accountId) = try await setUp()
        let newer = suiRead(epoch: 101, positions: [suiPosition(suiStakedSui(principal: 3_000_000_000))])
        let older = suiRead(epoch: 100, positions: [suiPosition(suiStakedSui(principal: 9_000_000_000))])

        try await database.saveStakingState(accountId: accountId, read: newer, startedAt: stakingDate(5))
        let applied = try await database.saveStakingState(accountId: accountId, read: older, startedAt: stakingDate(3))

        #expect(!applied)
        #expect(try await details(database, accountId).epoch == 101)
        #expect(try #require(try await database.fetchStaking(accountId: accountId)).staked == 3_000_000_000)
    }

    @Test func aReadKeepsTheDevicesOwnPendingRecord() async throws {
        let (database, accountId) = try await setUp()
        try await database.saveStakingState(accountId: accountId, read: suiRead(), startedAt: stakingDate(1))

        let submission = SuiPendingSubmission(
            prepared: try suiPrepared(), signature: Data([1]), createdAt: stakingDate(2)
        )
        #expect(try await database.claimSuiSubmission(accountId: accountId, submission: submission))

        try await database.saveStakingState(accountId: accountId, read: suiRead(epoch: 102), startedAt: stakingDate(3))

        #expect(try await details(database, accountId).pendingSubmissions == [submission])
    }

    @Test func onlyOneSubmissionCanBeClaimedAtATime() async throws {
        let (database, accountId) = try await setUp()
        try await database.saveStakingState(accountId: accountId, read: suiRead(), startedAt: stakingDate(1))

        let first = SuiPendingSubmission(prepared: try suiPrepared(), signature: Data([1]), createdAt: stakingDate(2))
        let second = SuiPendingSubmission(
            prepared: try suiPrepared(digestByte: 0xD2), signature: Data([2]), createdAt: stakingDate(3)
        )

        #expect(try await database.claimSuiSubmission(accountId: accountId, submission: first))
        #expect(try await database.claimSuiSubmission(accountId: accountId, submission: second) == false)
        #expect(try await details(database, accountId).pendingSubmissions == [first], "the refused claim wrote nothing")

        try await database.saveSuiPendingSubmissions(accountId: accountId, submissions: [])
        #expect(try await database.claimSuiSubmission(accountId: accountId, submission: second))
    }

    @Test func removingADigestTwiceNeverErasesALaterClaim() async throws {
        let (database, accountId) = try await setUp()
        try await database.saveStakingState(accountId: accountId, read: suiRead(), startedAt: stakingDate(1))

        let first = SuiPendingSubmission(prepared: try suiPrepared(), signature: Data([1]), createdAt: stakingDate(2))
        let second = SuiPendingSubmission(
            prepared: try suiPrepared(digestByte: 0xD2), signature: Data([2]), createdAt: stakingDate(3)
        )

        #expect(try await database.claimSuiSubmission(accountId: accountId, submission: first))
        #expect(try await database.removeSuiSubmission(accountId: accountId, digest: first.digest))
        #expect(try await database.claimSuiSubmission(accountId: accountId, submission: second))

        // The slower of two resolvers arrives with the first digest again.
        #expect(try await database.removeSuiSubmission(accountId: accountId, digest: first.digest) == false)
        #expect(try await details(database, accountId).pendingSubmissions == [second])
    }

    @Test func aBroadcastPlaceholderIsRemovedButARealRowIsNot() async throws {
        let database = try makeDatabaseService()
        let account = try await makeSuiStakingAccount(database)

        let placeholder = BlockchainTransaction(identifier: "PLACEHOLDER", status: .broadcast)
        let landed = BlockchainTransaction(identifier: "LANDED", status: .confirmed)
        try await database.saveTransactions([placeholder, landed], for: account)

        #expect(try await database.removeBroadcastPlaceholder(identifier: "PLACEHOLDER", for: account))
        #expect(try await database.removeBroadcastPlaceholder(identifier: "PLACEHOLDER", for: account) == false)
        #expect(try await database.removeBroadcastPlaceholder(identifier: "LANDED", for: account) == false)

        let remaining = try await database.fetchTransactions(accountId: try idOf(account))
        #expect(remaining.count == 1)
    }

    @Test func aBroadcastPlaceholderIsOnlyRecordedWhileTheSubmissionIsPending() async throws {
        let database = try makeDatabaseService()
        let account = try await makeSuiStakingAccount(database)
        let accountId = try idOf(account)
        try await database.saveStakingState(accountId: accountId, read: suiRead(), startedAt: stakingDate(1))
        let submission = SuiPendingSubmission(
            prepared: try suiPrepared(), signature: Data([1]), createdAt: stakingDate(2)
        )

        #expect(try await database.recordSuiBroadcast(digest: submission.digest, for: account) == false, "not claimed")

        #expect(try await database.claimSuiSubmission(accountId: accountId, submission: submission))
        #expect(try await database.recordSuiBroadcast(digest: submission.digest, for: account))
        #expect(try await database.fetchTransactions(accountId: accountId).count == 1)

        // Reconciliation proves it expired and cleans up; the original send's late response must not undo that.
        try await database.clearNonExecutedSuiSubmission(digest: submission.digest, for: account)
        #expect(try await details(database, accountId).pendingSubmissions.isEmpty)
        #expect(try await database.fetchTransactions(accountId: accountId).isEmpty, "claim and placeholder go together")

        #expect(try await database.recordSuiBroadcast(digest: submission.digest, for: account) == false)
        #expect(try await database.fetchTransactions(accountId: accountId).isEmpty)
    }

    @Test func clearingANonExecutionLeavesRealHistoryAndIsRepeatable() async throws {
        let database = try makeDatabaseService()
        let account = try await makeSuiStakingAccount(database)
        let accountId = try idOf(account)
        try await database.saveStakingState(accountId: accountId, read: suiRead(), startedAt: stakingDate(1))
        let submission = SuiPendingSubmission(
            prepared: try suiPrepared(), signature: Data([1]), createdAt: stakingDate(2)
        )
        #expect(try await database.claimSuiSubmission(accountId: accountId, submission: submission))

        // The same digest later shows up confirmed in history: cleanup must keep it.
        try await database.saveTransactions(
            [BlockchainTransaction(identifier: submission.digest, status: .confirmed)], for: account
        )

        try await database.clearNonExecutedSuiSubmission(digest: submission.digest, for: account)
        try await database.clearNonExecutedSuiSubmission(digest: submission.digest, for: account)

        #expect(try await details(database, accountId).pendingSubmissions.isEmpty)
        #expect(try await database.fetchTransactions(accountId: accountId).count == 1)
    }

    @Test func claimingNeedsAPositionToHoldTheRecord() async throws {
        let (database, accountId) = try await setUp()
        let submission = SuiPendingSubmission(
            prepared: try suiPrepared(), signature: Data([1]), createdAt: stakingDate(1)
        )

        await #expect(throws: ReefrError.notFound) {
            try await database.claimSuiSubmission(accountId: accountId, submission: submission)
        }
    }

    @Test func theNextEpochComesFromTheNodesTiming() async throws {
        let (database, accountId) = try await setUp()
        try await database.saveStakingState(accountId: accountId, read: suiRead(), startedAt: stakingDate(1))

        let next = try #require(try await details(database, accountId).nextEpochDate)
        #expect(next.timeIntervalSince1970 == 1_800_086_400)
    }
}
