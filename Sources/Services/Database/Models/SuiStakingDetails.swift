//
//  SuiStakingDetails.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 06.11.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation
import SwiftData
import WalletKit

/// Sui: the receipts as read, the epoch's timing, and signed transactions whose outcome isn't known
/// yet. There is no rate: Sui has no source for it. See ADR-060.
struct SuiStakingDetails: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var epoch: UInt64
    var epochDurationMs: UInt64
    var epochStartTimestampMs: UInt64
    /// Signed transactions not yet known to have landed or expired; staking is paused meanwhile.
    var pendingSubmissions: [SuiPendingSubmission]
    var positions: [SuiStakePosition]
    var version = Self.currentVersion

    /// Principal of every receipt: pending and retired ones stay locked until withdrawn.
    var stakedMist: UInt64 {
        positions.map(\.stake.principal).saturatingSum
    }

    /// The estimates that are known; see ``isRewardsComplete``.
    var estimatedRewardsMist: UInt64 {
        positions.compactMap(\.estimatedReward).saturatingSum
    }

    var isRewardsComplete: Bool {
        positions.allSatisfy { $0.estimatedReward != nil }
    }

    /// When the next epoch begins, if the node reported timing.
    var nextEpochDate: Date? {
        guard epochStartTimestampMs > 0, epochDurationMs > 0 else {
            return nil
        }

        return Date(timeIntervalSince1970: Double(epochStartTimestampMs + epochDurationMs) / 1_000)
    }
}

// MARK: - Merging

/// Observations arrive from overlapping requests in any order. Each carries the time its request
/// started; a part is replaced only by an observation that started later than the one it holds,
/// so an older response can't undo a newer one. Ties are discarded.
extension Staking {
    /// A first Sui position, from a full read.
    static func sui(
        accountId: PersistentIdentifier,
        tokenId: PersistentIdentifier,
        read: SuiStakingRead,
        startedAt: Date
    ) -> Staking {
        let details = suiDetails(stored: nil, read: read)

        return Staking(
            accountId: accountId,
            apr: nil,
            details: .sui(details),
            revision: 1,
            rewards: BigUInt(details.estimatedRewardsMist),
            staked: BigUInt(details.stakedMist),
            resourcesObservedAt: startedAt,
            stateObservedAt: startedAt,
            tokenId: tokenId
        )
    }

    /// This position after a Sui read that started at `startedAt`; `nil` if nothing in it is newer.
    /// Pending submissions aren't part of a read, so they are kept.
    func applying(read: SuiStakingRead, startedAt: Date) -> Staking? {
        guard case let .sui(stored) = details, startedAt > stateObservedAt else {
            return nil
        }

        var result = self
        let merged = Self.suiDetails(stored: stored, read: read)

        result.details = .sui(merged)
        result.revision += 1
        result.rewards = BigUInt(merged.estimatedRewardsMist)
        result.resourcesObservedAt = startedAt
        result.staked = BigUInt(merged.stakedMist)
        result.stateObservedAt = startedAt

        return result
    }

    /// This position with its pending Sui submissions replaced. Not ordered: they are this device's
    /// own record, written before a broadcast and after each reconciliation.
    func applying(pendingSubmissions: [SuiPendingSubmission]) -> Staking? {
        guard case var .sui(stored) = details else {
            return nil
        }

        stored.pendingSubmissions = pendingSubmissions

        var result = self
        result.details = .sui(stored)
        result.revision += 1

        return result
    }

    /// This position with `submission` as its only pending Sui submission, or `nil` if it isn't a Sui
    /// position or another submission is still unresolved.
    func claiming(_ submission: SuiPendingSubmission) -> Staking? {
        guard case let .sui(stored) = details, stored.pendingSubmissions.isEmpty else {
            return nil
        }

        return applying(pendingSubmissions: [submission])
    }

    private static func suiDetails(stored: SuiStakingDetails?, read: SuiStakingRead) -> SuiStakingDetails {
        SuiStakingDetails(
            epoch: read.epoch,
            epochDurationMs: read.epochDurationMs,
            epochStartTimestampMs: read.epochStartTimestampMs,
            pendingSubmissions: stored?.pendingSubmissions ?? [],
            positions: read.positions
        )
    }
}
