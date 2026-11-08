//
//  SolanaStakingDetails.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 06.11.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation
import SwiftData
import WalletKit

/// Solana: the stake accounts as read, what's known of last epoch's rewards, and transactions whose
/// outcome isn't known yet. See ADR-054.
struct SolanaStakingDetails: Codable, Equatable, Sendable {
    /// What a delegated validator is called and pays; any of it may be unknown.
    struct Validator: Codable, Equatable, Sendable {
        var commission: Int?
        var name: String?
        /// Percent, kept as text: JSON numbers would round-trip a `Decimal` through `Double`.
        var rate: String?

        var apy: Decimal? {
            rate.flatMap { Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) }
        }

        init(commission: Int?, name: String?, apy: Decimal?) {
            self.commission = commission
            self.name = name
            rate = apy.map { "\($0)" }
        }
    }

    static let currentVersion = 1

    var clock: SolanaClock
    var discovery: SolanaStakeDiscovery
    /// When ``slotDuration`` and ``slotsRemainingInEpoch`` were read.
    var observedAt: Date
    /// Signed transactions not yet known to have landed or expired; staking is paused meanwhile.
    var pendingSubmissions: [SolanaPendingSubmission]
    var positions: [SolanaStakePosition]
    /// Addresses that left the position, by the epoch that was detected: rewards earned before
    /// they left are still owed to last epoch's total.
    var retiredAddresses: [String: UInt64]
    var rewards: SolanaStakingRewards?
    var slotDuration: Double?
    var slotsRemainingInEpoch: UInt64
    /// Delegated validators only, by vote address.
    var validators: [String: Validator]
    var version = Self.currentVersion

    /// The epoch rewards are looked up for, `nil` before the first epoch ends.
    var targetRewardEpoch: UInt64? {
        clock.epoch > 0 ? clock.epoch - 1 : nil
    }

    /// Stake that's earning or about to: active and warming up, whoever holds its authorities.
    var stakedLamports: UInt64 {
        positions
            .filter { $0.status == .active || $0.status == .activating }
            .compactMap { $0.account.delegation?.stake }
            .saturatingSum
    }

    /// The delegated validators' rates, weighted by stake. `nil` unless every one has a known rate.
    var apy: Decimal? {
        var weighted = Decimal(0)
        var total = Decimal(0)

        for position in positions where position.status == .active || position.status == .activating {
            guard
                let delegation = position.account.delegation,
                let rate = validators[delegation.voter]?.apy
            else {
                return nil
            }

            weighted += rate * Decimal(delegation.stake)
            total += Decimal(delegation.stake)
        }

        return total > 0 ? weighted / total : nil
    }

    /// `retired` after a read: what left is added with the read's epoch, what's back is removed,
    /// and what was gone for the whole target epoch is dropped.
    static func retired(_ stored: SolanaStakingDetails?, read: SolanaStakingRead) -> [String: UInt64] {
        let current = Set(read.accounts.map(\.address))
        var retired = stored?.retiredAddresses ?? [:]

        for position in stored?.positions ?? [] where !current.contains(position.account.address) {
            retired[position.account.address] = read.clock.epoch
        }

        let target = read.clock.epoch > 0 ? read.clock.epoch - 1 : 0

        return retired.filter { address, detected in
            !current.contains(address) && target <= detected
        }
    }

    /// Whether rewards should be asked for: not if the stored answer is fully resolved for the
    /// same epoch and addresses; if it has unknowns, at most hourly.
    static func needsRewards(
        stored: SolanaStakingRewards?,
        epoch: UInt64,
        addresses: Set<String>,
        now: Date
    ) -> Bool {
        guard let stored, stored.epoch == epoch, Set(stored.queriedAddresses) == addresses else {
            return true
        }

        return !stored.unknownAddresses.isEmpty && now.timeIntervalSince(stored.attemptedAt) >= rewardRetryInterval
    }

    private static let rewardRetryInterval: TimeInterval = 3_600
}

/// What one Solana position read found. Rewards and validators are best effort: `nil`
/// rewards keep what's stored, and absent validator names never erase known ones.
struct SolanaStakingObservation: Sendable {
    let read: SolanaStakingRead
    var rewards: SolanaStakingRewards?
    var validators: [String: SolanaStakingDetails.Validator] = [:]
}

// MARK: - Merging

/// Observations arrive from overlapping requests in any order. Each carries the time its request
/// started; a part is replaced only by an observation that started later than the one it holds,
/// so an older response can't undo a newer one. Ties are discarded.
extension Staking {
    /// A first Solana position, from a full read.
    static func solana(
        accountId: PersistentIdentifier,
        tokenId: PersistentIdentifier,
        observation: SolanaStakingObservation,
        startedAt: Date
    ) -> Staking {
        let details = solanaDetails(stored: nil, observation: observation, at: startedAt)

        return Staking(
            accountId: accountId,
            apr: details.apy,
            details: .solana(details),
            revision: 1,
            rewards: currentRewards(of: details),
            staked: BigUInt(details.stakedLamports),
            resourcesObservedAt: startedAt,
            stateObservedAt: startedAt,
            tokenId: tokenId
        )
    }

    /// This position after a Solana read that started at `startedAt`; `nil` if nothing in it is newer.
    /// Pending submissions aren't part of a read, so they are kept.
    func applying(observation: SolanaStakingObservation, startedAt: Date) -> Staking? {
        guard case let .solana(stored) = details, startedAt > stateObservedAt else {
            return nil
        }

        var result = self
        let merged = Self.solanaDetails(stored: stored, observation: observation, at: startedAt)

        result.apr = merged.apy
        result.details = .solana(merged)
        result.revision += 1
        result.rewards = Self.currentRewards(of: merged)
        result.resourcesObservedAt = startedAt
        result.staked = BigUInt(merged.stakedLamports)
        result.stateObservedAt = startedAt

        return result
    }

    /// This position with its pending submissions replaced. Not ordered: they are this device's
    /// own record, written before a broadcast and after each reconciliation.
    func applying(pendingSubmissions: [SolanaPendingSubmission]) -> Staking? {
        guard case var .solana(stored) = details else {
            return nil
        }

        stored.pendingSubmissions = pendingSubmissions

        var result = self
        result.details = .solana(stored)
        result.revision += 1

        return result
    }

    private static func solanaDetails(
        stored: SolanaStakingDetails?,
        observation: SolanaStakingObservation,
        at date: Date
    ) -> SolanaStakingDetails {
        let read = observation.read
        let voters = Set(read.accounts.compactMap(\.delegation?.voter))
        var validators = (stored?.validators ?? [:]).filter { voters.contains($0.key) }

        for (voter, fresh) in observation.validators where voters.contains(voter) {
            var known = validators[voter] ?? SolanaStakingDetails.Validator(commission: nil, name: nil, apy: nil)
            known.commission = fresh.commission ?? known.commission
            known.name = fresh.name ?? known.name
            known.rate = fresh.rate ?? known.rate
            validators[voter] = known
        }

        return SolanaStakingDetails(
            clock: read.clock,
            discovery: read.discovery,
            observedAt: date,
            pendingSubmissions: stored?.pendingSubmissions ?? [],
            positions: read.positions,
            retiredAddresses: SolanaStakingDetails.retired(stored, read: read),
            rewards: observation.rewards ?? stored?.rewards,
            slotDuration: read.slotDuration ?? read.fallbackSlotDuration() ?? stored?.slotDuration,
            slotsRemainingInEpoch: read.slotsRemainingInEpoch,
            validators: validators
        )
    }

    /// Rewards of the shared column: only last epoch's, whatever older answer the details keep.
    private static func currentRewards(of details: SolanaStakingDetails) -> BigUInt {
        details.rewards?.epoch == details.targetRewardEpoch ? BigUInt(details.rewards?.lamports ?? 0) : 0
    }
}
