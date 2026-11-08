//
//  CardanoStakingDetails.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 06.11.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation
import SwiftData
import WalletKit

/// Cardano: the stake key's registration, delegation and rewards as read, the pool and DRep names
/// last known, and this device's own record of transactions and multi-step workflows. See ADR-059.
struct CardanoStakingDetails: Codable, Equatable, Sendable {
    /// What a delegated pool is called and charges; any of it may be unknown.
    struct PoolSummary: Codable, Equatable, Sendable {
        var fixedCost: UInt64?
        var marginCost: Double?
        var name: String?
        let poolId: String
        var ticker: String?

        init(poolId: String, pool: CardanoPool? = nil) {
            self.poolId = poolId
            fixedCost = pool?.fixedCost
            marginCost = pool?.marginCost
            name = pool?.name
            ticker = pool?.ticker
        }
    }

    static let currentVersion = 1

    var drep: CardanoDRep?
    var drepName: String?
    var epoch: CardanoEpochTiming
    var latestReward: CardanoReward?
    /// Signed transactions not yet known to have landed or expired; staking is paused meanwhile.
    var pendingSubmissions: [CardanoPendingSubmission]
    var pool: PoolSummary?
    var refundDeposit: UInt64?
    var registered: Bool
    var totalEarned: BigUInt
    /// A withdrawal or deregistration waiting for a vote delegation first.
    var workflow: CardanoStakingWorkflow?
    var version = Self.currentVersion
}

/// Withdrawing rewards needs a DRep. With none delegated, the action runs as two transactions:
/// a vote delegation, then the action itself. This device's own record, never overwritten by reads.
struct CardanoStakingWorkflow: Codable, Equatable, Sendable {
    enum Intent: String, Codable, Sendable {
        case stopStaking
        case withdraw
    }

    /// Why a step has to be done again.
    enum Notice: String, Codable, Sendable {
        case expired
        case failed
    }

    enum Phase: Codable, Equatable, Sendable {
        /// Step 1 is waiting to be signed, or didn't land (`notice`).
        case needsVoteDelegation(notice: Notice?)
        case voteDelegationPending(hash: String)
        /// Step 1 confirmed and the read shows the DRep; step 2 is waiting, or didn't land (`notice`).
        case readyForFinalStep(notice: Notice?)
        case finalStepPending(hash: String)
    }

    var drep: CardanoDRep
    let intent: Intent
    var phase: Phase
    var updatedAt: Date
}

/// What one Cardano position read found. Names are best effort: absent ones never erase known ones.
struct CardanoStakingObservation: Sendable {
    let read: CardanoStakingRead
    var drepName: String?
    var pool: CardanoPool?
}

// MARK: - Merging

/// Observations arrive from overlapping requests in any order. Each carries the time its request
/// started; a part is replaced only by an observation that started later than the one it holds,
/// so an older response can't undo a newer one. Ties are discarded.
extension Staking {
    /// A first Cardano position, from a full read.
    static func cardano(
        accountId: PersistentIdentifier,
        tokenId: PersistentIdentifier,
        observation: CardanoStakingObservation,
        startedAt: Date
    ) -> Staking {
        Staking(
            accountId: accountId,
            apr: nil,
            details: .cardano(cardanoDetails(stored: nil, observation: observation)),
            revision: 1,
            rewards: observation.read.withdrawable,
            staked: observation.read.controlled,
            resourcesObservedAt: startedAt,
            stateObservedAt: startedAt,
            tokenId: tokenId
        )
    }

    /// This position after a Cardano read that started at `startedAt`; `nil` if nothing in it is newer.
    /// Pending submissions and the workflow aren't part of a read, so they are kept.
    func applying(observation: CardanoStakingObservation, startedAt: Date) -> Staking? {
        guard case let .cardano(stored) = details, startedAt > stateObservedAt else {
            return nil
        }

        var result = self
        result.details = .cardano(Self.cardanoDetails(stored: stored, observation: observation))
        result.revision += 1
        result.rewards = observation.read.withdrawable
        result.resourcesObservedAt = startedAt
        result.staked = observation.read.controlled
        result.stateObservedAt = startedAt

        return result
    }

    /// This position with its pending Cardano submissions replaced. Not ordered: they are this
    /// device's own record, written before a broadcast and after each reconciliation.
    func applying(pendingSubmissions: [CardanoPendingSubmission]) -> Staking? {
        guard case var .cardano(stored) = details else {
            return nil
        }

        stored.pendingSubmissions = pendingSubmissions

        var result = self
        result.details = .cardano(stored)
        result.revision += 1

        return result
    }

    /// This position with the pending submission `hash` removed and the workflow changed in the same
    /// write: a launch between the two would leave a workflow waiting on a submission nobody checks.
    func applying(
        resolved hash: String,
        workflow change: (CardanoStakingWorkflow?) -> CardanoStakingWorkflow?
    ) -> Staking? {
        guard case var .cardano(stored) = details else {
            return nil
        }

        stored.pendingSubmissions.removeAll { $0.hash == hash }
        stored.workflow = change(stored.workflow)

        var result = self
        result.details = .cardano(stored)
        result.revision += 1

        return result
    }

    /// This position with its workflow replaced (`nil` clears it). Not ordered, like pending submissions.
    func applying(workflow: CardanoStakingWorkflow?) -> Staking? {
        guard case var .cardano(stored) = details else {
            return nil
        }

        stored.workflow = workflow

        var result = self
        result.details = .cardano(stored)
        result.revision += 1

        return result
    }

    private static func cardanoDetails(
        stored: CardanoStakingDetails?,
        observation: CardanoStakingObservation
    ) -> CardanoStakingDetails {
        let read = observation.read
        var pool = read.poolId.map { poolId in
            stored?.pool?.poolId == poolId ? stored?.pool ?? .init(poolId: poolId) : .init(poolId: poolId)
        }

        if let fresh = observation.pool, var known = pool, fresh.poolId == known.poolId {
            known.fixedCost = fresh.fixedCost
            known.marginCost = fresh.marginCost
            known.name = fresh.name ?? known.name
            known.ticker = fresh.ticker ?? known.ticker
            pool = known
        }

        let sameDRep = stored?.drep == read.drep
        let drepName = observation.drepName ?? (sameDRep ? stored?.drepName : nil)

        return CardanoStakingDetails(
            drep: read.drep,
            drepName: read.drep == nil ? nil : drepName,
            epoch: read.epoch,
            latestReward: read.latestReward ?? stored?.latestReward,
            pendingSubmissions: stored?.pendingSubmissions ?? [],
            pool: pool,
            refundDeposit: read.refundDeposit,
            registered: read.registered,
            totalEarned: read.rewardsSum,
            workflow: stored?.workflow
        )
    }
}
