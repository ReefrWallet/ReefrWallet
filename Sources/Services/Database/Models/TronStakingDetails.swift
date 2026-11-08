//
//  TronStakingDetails.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 06.11.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation
import SwiftData
import WalletKit

/// Tron: the node's position plus what the voted representatives are called and pay.
struct TronStakingDetails: Codable, Equatable, Sendable {
    /// Name and annual rate of a voted representative; either may be unknown.
    struct Representative: Codable, Equatable, Sendable {
        var name: String?
        /// Percent, kept as text: JSON numbers would round-trip a `Decimal` through `Double`.
        var rate: String?

        var apr: Decimal? {
            rate.flatMap { Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) }
        }

        init(name: String?, apr: Decimal?) {
            self.name = name
            rate = apr.map { "\($0)" }
        }
    }

    static let currentVersion = 1

    /// Voted representatives only, by base58 address.
    var representatives: [String: Representative]
    var state: TronStakingState
    var version = Self.currentVersion

    /// Annual rate of the rewards: the voted representatives' rates, weighted by votes.
    /// `nil` unless there are votes and every voted representative has a known rate.
    var apr: Decimal? {
        guard !state.votes.isEmpty else {
            return nil
        }

        var weighted = Decimal(0)
        var total = Decimal(0)

        for vote in state.votes {
            guard let rate = representatives[vote.address.string]?.apr else {
                return nil
            }

            weighted += rate * Decimal(vote.count)
            total += Decimal(vote.count)
        }

        return total > 0 ? weighted / total : nil
    }
}

// MARK: - Merging

/// Observations arrive from overlapping requests in any order. Each carries the time its request
/// started; a part is replaced only by an observation that started later than the one it holds,
/// so an older response can't undo a newer one. Ties are discarded.
extension Staking {
    /// A first position, from a full state read.
    static func tron(
        accountId: PersistentIdentifier,
        tokenId: PersistentIdentifier,
        state: TronStakingState,
        representatives: [String: TronStakingDetails.Representative],
        startedAt: Date
    ) -> Staking {
        let details = TronStakingDetails(
            representatives: voted(representatives, in: state),
            state: state
        )

        return Staking(
            accountId: accountId,
            apr: details.apr,
            details: .tron(details),
            revision: 1,
            rewards: BigUInt(state.rewards),
            staked: BigUInt(state.totalStaked),
            resourcesObservedAt: startedAt,
            stateObservedAt: startedAt,
            tokenId: tokenId
        )
    }

    /// This position after a full state read that started at `startedAt`; `nil` if nothing in it is newer.
    ///
    /// The read's bandwidth and energy replace stored ones only if they are newer too, and fresh
    /// representative names and rates only fill what the stored ones lack or have changed:
    /// a failed or node-only lookup (no names, no rates) never erases what was known.
    func applying(
        state: TronStakingState,
        representatives: [String: TronStakingDetails.Representative],
        startedAt: Date
    ) -> Staking? {
        guard case let .tron(stored) = details else {
            return nil
        }

        // Resources are never older than the state beside them, so an older read adds nothing.
        guard startedAt > stateObservedAt else {
            return nil
        }

        let newerResources = startedAt > resourcesObservedAt
        let kept = newerResources ? state : state.replacingResources(
            TronResourceUsage(bandwidth: stored.state.bandwidth, energy: stored.state.energy)
        )

        var merged = Self.voted(stored.representatives, in: kept)

        for (address, fresh) in Self.voted(representatives, in: kept) {
            var known = merged[address] ?? TronStakingDetails.Representative(name: nil, apr: nil)
            known.name = fresh.name ?? known.name
            known.rate = fresh.rate ?? known.rate
            merged[address] = known
        }

        var result = self
        let details = TronStakingDetails(representatives: merged, state: kept)

        result.apr = details.apr
        result.details = .tron(details)
        result.revision += 1
        result.rewards = BigUInt(state.rewards)
        result.staked = BigUInt(state.totalStaked)
        result.stateObservedAt = startedAt

        if newerResources {
            result.resourcesObservedAt = startedAt
        }

        return result
    }

    /// This position with new bandwidth and energy from a read that started at `startedAt`;
    /// `nil` if the stored ones are as new or newer.
    func applying(resources: TronResourceUsage, startedAt: Date) -> Staking? {
        guard case let .tron(stored) = details, startedAt > resourcesObservedAt else {
            return nil
        }

        var result = self
        result.details = .tron(TronStakingDetails(
            representatives: stored.representatives,
            state: stored.state.replacingResources(resources)
        ))

        result.revision += 1
        result.resourcesObservedAt = startedAt

        return result
    }

    private static func voted(
        _ representatives: [String: TronStakingDetails.Representative],
        in state: TronStakingState
    ) -> [String: TronStakingDetails.Representative] {
        let addresses = Set(state.votes.map(\.address.string))
        return representatives.filter { addresses.contains($0.key) }
    }
}
