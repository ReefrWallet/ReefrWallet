//
//  TronStakingPositionLoader.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 06.11.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation
import SwiftData
import WalletKit

// MARK: - TronStakingSource

/// Where a Tron account's staking position is read from.
protocol TronStakingSource: Sendable {
    func representatives(for account: Account) async throws -> [TronRepresentative]
    func state(for account: Account) async throws -> TronStakingState
}

struct TronNodeStakingSource: TronStakingSource {
    func representatives(for account: Account) async throws -> [TronRepresentative] {
        try await DI.injectOrFail(BlockchainClientProvider.self).tronClient(for: account).representatives()
    }

    func state(for account: Account) async throws -> TronStakingState {
        let client = try DI.injectOrFail(BlockchainClientProvider.self).tronClient(for: account)
        return try await client.stakingState(for: TronAddress(string: account.address))
    }
}

// MARK: - TronStakingPositionLoader

/// Stores the Stake 2.0 position of Tron accounts: the ones it reads itself
/// (``load(_:accountId:)``) and the ones other code already fetched
/// (``record(state:startedAt:account:)``, ``record(resources:startedAt:account:)``).
actor TronStakingPositionLoader: StakingPositionLoading {
    private struct CachedRepresentatives {
        let fetchedAt: Date
        let list: [TronRepresentative]
    }

    /// A list without names or rates is the node's fallback; TronScan may be back soon.
    private static let degradedLifetime: TimeInterval = 60
    private static let representativesLifetime: TimeInterval = 3_600

    private let databaseService: DatabaseService
    private let now: @Sendable () -> Date
    private let source: any TronStakingSource

    private var cache: [String: CachedRepresentatives] = [:]

    init(
        databaseService: DatabaseService? = nil,
        source: (any TronStakingSource)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.databaseService = databaseService ?? DI.injectOrFail(DatabaseService.self)
        self.now = now
        self.source = source ?? TronNodeStakingSource()
    }

    // MARK: StakingPositionLoading

    nonisolated func supports(_ blockchain: Blockchain) -> Bool {
        if case .tron = blockchain {
            true
        } else {
            false
        }
    }

    /// - Throws: if the position itself can't be read. Representatives are best effort.
    func load(_ account: Account, accountId: PersistentIdentifier) async throws {
        let startedAt = now()

        async let state = source.state(for: account)
        async let representatives = representatives(for: account)

        let position = try await state
        let known = await representatives

        let voted = position.votes.compactMap { vote -> (String, TronStakingDetails.Representative)? in
            known.first { $0.address == vote.address }.map {
                (vote.address.string, TronStakingDetails.Representative(name: $0.name, apr: $0.apr))
            }
        }

        try await databaseService.saveStakingState(
            accountId: accountId,
            state: position,
            representatives: Dictionary(voted, uniquingKeysWith: { first, _ in first }),
            startedAt: startedAt
        )
    }

    // MARK: Representatives

    /// The votable representatives, cached per network and endpoint. A failed lookup yields
    /// the last good list (or none) and never evicts it.
    func representatives(for account: Account) async -> [TronRepresentative] {
        let key = "\((try? account.blockchain.asJSONString()) ?? "")|\(account.rpcURLOverride?.absoluteString ?? "")"
        let cached = cache[key]

        if let cached {
            let degraded = cached.list.allSatisfy { $0.name == nil && $0.apr == nil }
            let lifetime = degraded ? Self.degradedLifetime : Self.representativesLifetime

            if now().timeIntervalSince(cached.fetchedAt) < lifetime {
                return cached.list
            }
        }

        let fetchedAt = now()

        guard let list = try? await source.representatives(for: account) else {
            return cached?.list ?? []
        }

        cache[key] = CachedRepresentatives(fetchedAt: fetchedAt, list: list)
        return list
    }

    // MARK: Recording

    /// Stores a position another read already fetched, which started at `startedAt`.
    /// Best effort: failures are logged.
    func record(state: TronStakingState, startedAt: Date, account: Account) async {
        guard supports(account.blockchain), let accountId = account.id else {
            return
        }

        do {
            try await databaseService.saveStakingState(
                accountId: accountId,
                state: state,
                representatives: [:],
                startedAt: startedAt
            )
        } catch {
            printError("\(account.name) staking: \(error)")
        }
    }

    /// Stores allowances another read already fetched, which started at `startedAt`.
    /// Best effort: failures are logged.
    func record(resources: TronResourceUsage, startedAt: Date, account: Account) async {
        guard supports(account.blockchain), let accountId = account.id else {
            return
        }

        do {
            try await databaseService.saveStakingResources(
                accountId: accountId,
                resources: resources,
                startedAt: startedAt
            )
        } catch {
            printError("\(account.name) staking: \(error)")
        }
    }
}
