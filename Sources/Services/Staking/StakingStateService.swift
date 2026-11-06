//
//  StakingStateService.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 06.11.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation
import SwiftData
import WalletKit

// MARK: - StakingPositionLoading

/// Reads and stores the staking position of the accounts of one chain family.
///
/// Adding staking to another blockchain means a new loader (like ``TronStakingPositionLoader``)
/// listed in ``StakingStateService``; nothing else here changes.
protocol StakingPositionLoading: Sendable {
    /// Whether this loader serves accounts of `blockchain`.
    func supports(_ blockchain: Blockchain) -> Bool

    /// Re-reads `account`'s position and stores it, throwing if the position can't be read.
    func load(_ account: Account, accountId: PersistentIdentifier) async throws
}

// MARK: - StakingRefreshing

/// What balance updates need of staking: a full re-read of one account's position.
protocol StakingRefreshing: Sendable {
    func refresh(_ account: Account) async throws
}

// MARK: - StakingStateService

/// Keeps each staking account's stored position (see ``Staking``) current, whatever the chain.
///
/// This actor decides *when* to read: overlapping requests for an account are shared, and a read
/// after a transaction never settles for one that began before it. The chain's
/// ``StakingPositionLoading`` decides *what* to read and store; which observation wins is decided
/// by the stored position's ordering rules, so reads may finish in any order.
actor StakingStateService: StakingRefreshing {
    private struct FollowUp {
        let task: Task<Void, any Error>
        var started = false
    }

    private let loaders: [any StakingPositionLoading]

    private var followUps: [PersistentIdentifier: FollowUp] = [:]
    private var inFlight: [PersistentIdentifier: Task<Void, any Error>] = [:]

    /// - Parameter loaders: One per chain family; defaults to the ones of the DI container.
    init(loaders: [any StakingPositionLoading]? = nil) {
        self.loaders = loaders ?? [DI.injectOrFail(TronStakingPositionLoader.self)]
    }

    /// Re-reads `account`'s position and stores it. Callers arriving while a read is in
    /// flight share it. Does nothing for chains without staking.
    ///
    /// - Throws: if the position itself can't be read.
    func refresh(_ account: Account) async throws {
        guard let loader = loader(for: account), let accountId = account.id else {
            return
        }

        if let running = inFlight[accountId] {
            return try await running.value
        }

        let task = Task { try await loader.load(account, accountId: accountId) }
        inFlight[accountId] = task
        defer { clear(task, accountId: accountId) }

        try await task.value
    }

    /// Like ``refresh(_:)``, for after a transaction changed the position: a read already in
    /// flight may have started before the change, so this waits for it and then reads again.
    /// Callers whose follow-up hasn't started yet share one.
    func refreshAfterChange(_ account: Account) async throws {
        guard let loader = loader(for: account), let accountId = account.id else {
            return
        }

        if let pending = followUps[accountId], !pending.started {
            return try await pending.task.value
        }

        let earlier = inFlight[accountId]
        let task = Task {
            _ = await earlier?.result
            begin(accountId)
            try await loader.load(account, accountId: accountId)
        }

        followUps[accountId] = FollowUp(task: task)
        inFlight[accountId] = task
        defer { clear(task, accountId: accountId) }

        try await task.value
    }
}

// MARK: - Private

private extension StakingStateService {
    func begin(_ accountId: PersistentIdentifier) {
        followUps[accountId]?.started = true
    }

    func clear(_ task: Task<Void, any Error>, accountId: PersistentIdentifier) {
        if inFlight[accountId] == task {
            inFlight[accountId] = nil
        }

        if followUps[accountId]?.task == task {
            followUps[accountId] = nil
        }
    }

    func loader(for account: Account) -> (any StakingPositionLoading)? {
        loaders.first { $0.supports(account.blockchain) }
    }
}
