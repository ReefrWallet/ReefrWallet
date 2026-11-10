//
//  SolanaStakingPositionLoader.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 06.11.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation
import SwiftData
import WalletKit

// MARK: - SolanaStakingSource

/// Where a Solana account's stake is read from and its transactions go.
protocol SolanaStakingSource: Sendable {
    func availableBalance(for account: Account) async throws -> UInt64
    func blockHeight(for account: Account) async throws -> UInt64
    func broadcast(_ prepared: SolanaPreparedStaking, signature: Data, account: Account) async throws -> String
    func minimumDelegation(for account: Account) async throws -> UInt64
    func prepare(_ action: SolanaStakingAction, account: Account) async throws -> SolanaPreparedStaking
    func read(for account: Account, known: [String]) async throws -> SolanaStakingRead
    func reconcile(
        _ pending: SolanaPendingSubmission,
        account: Account,
        checkpoint: @escaping @Sendable (SolanaPendingSubmission) async -> Void
    ) async -> SolanaSubmissionUpdate
    func recordBroadcast(signature: String, account: Account) async
    func rent(for account: Account) async throws -> UInt64
    func rewards(
        for account: Account,
        read: SolanaStakingRead,
        retired: [String]
    ) async throws -> SolanaStakingRewards?
    func sign(_ prepared: SolanaPreparedStaking, account: Account) async throws -> Data
    func signatureStatus(_ signature: String, account: Account) async throws -> SolanaSignatureStatus
    func validators(for account: Account) async throws -> [SolanaValidator]
}

struct SolanaNodeStakingSource: SolanaStakingSource {
    private func client(_ account: Account) throws -> SolanaRPCClient {
        try DI.injectOrFail(BlockchainClientProvider.self).solanaClient(for: account)
    }

    func availableBalance(for account: Account) async throws -> UInt64 {
        UInt64(clamping: try await client(account).getNativeBalance(SolanaAddress(string: account.address)))
    }

    func blockHeight(for account: Account) async throws -> UInt64 {
        try await client(account).blockHeight(commitment: .confirmed)
    }

    func broadcast(_ prepared: SolanaPreparedStaking, signature: Data, account: Account) async throws -> String {
        try await DI.injectOrFail(TransactionService.self)
            .sendTransaction(prepared.unsigned, signature, account: account)
    }

    func minimumDelegation(for account: Account) async throws -> UInt64 {
        try await client(account).minimumDelegation()
    }

    func prepare(_ action: SolanaStakingAction, account: Account) async throws -> SolanaPreparedStaking {
        try await client(account).prepareStaking(action, owner: SolanaAddress(string: account.address))
    }

    func read(for account: Account, known: [String]) async throws -> SolanaStakingRead {
        try await client(account).stakingRead(owner: SolanaAddress(string: account.address), known: known)
    }

    func reconcile(
        _ pending: SolanaPendingSubmission,
        account: Account,
        checkpoint: @escaping @Sendable (SolanaPendingSubmission) async -> Void
    ) async -> SolanaSubmissionUpdate {
        guard let client = try? client(account) else {
            return .unresolved(pending)
        }

        return await client.reconcile(pending, checkpoint: checkpoint)
    }

    func recordBroadcast(signature: String, account: Account) async {
        await DI.injectOrFail(TransactionSyncService.self).recordBroadcast(identifier: signature, account: account)
    }

    func rent(for account: Account) async throws -> UInt64 {
        try await client(account).stakeAccountRent()
    }

    func rewards(
        for account: Account,
        read: SolanaStakingRead,
        retired: [String]
    ) async throws -> SolanaStakingRewards? {
        try await client(account).stakingRewards(read: read, retired: retired)
    }

    func sign(_ prepared: SolanaPreparedStaking, account: Account) async throws -> Data {
        try await DI.injectOrFail(TransactionService.self).signTransaction(prepared.unsigned, account: account)
    }

    func signatureStatus(_ signature: String, account: Account) async throws -> SolanaSignatureStatus {
        try await client(account).signatureStatus(signature, searchHistory: false)
    }

    func validators(for account: Account) async throws -> [SolanaValidator] {
        try await client(account).validators()
    }
}

// MARK: - SolanaStakingPositionLoader

/// Stores the stake accounts of Solana accounts and reconciles their unresolved transactions.
/// See ADR-054 for what a read may replace.
actor SolanaStakingPositionLoader: StakingPositionLoading {
    private struct CachedValidators {
        let fetchedAt: Date
        let list: [SolanaValidator]
    }

    /// A list without names or rates is the node's fallback; the indexer may be back soon.
    private static let degradedLifetime: TimeInterval = 60
    private static let validatorsLifetime: TimeInterval = 3_600

    private let databaseService: DatabaseService
    private let now: @Sendable () -> Date
    private let onResolved: @Sendable (Account) async -> Void
    private let source: any SolanaStakingSource

    private var cache: [String: CachedValidators] = [:]
    private var latestUpdates: [String: SolanaSubmissionUpdate] = [:]
    private var reconciling: [PersistentIdentifier: Task<Void, Never>] = [:]

    /// - Parameter onResolved: Runs after a submission resolves, for what it changed: by
    ///   default the position and spendable balance, also after a failure, which still cost a fee.
    init(
        databaseService: DatabaseService? = nil,
        source: (any SolanaStakingSource)? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        onResolved: (@Sendable (Account) async -> Void)? = nil
    ) {
        self.databaseService = databaseService ?? DI.injectOrFail(DatabaseService.self)
        self.now = now
        self.onResolved = onResolved ?? { account in
            async let position: Void? = try? DI.injectOrFail(StakingStateService.self).refreshAfterChange(account)
            try? await DI.injectOrFail(BalancesService.self).updateBalances(account, includeStaking: false)
            _ = await position
        }

        self.source = source ?? SolanaNodeStakingSource()
    }

    // MARK: StakingPositionLoading

    nonisolated func supports(_ blockchain: Blockchain) -> Bool {
        if case .solana = blockchain {
            true
        } else {
            false
        }
    }

    /// - Throws: if the position can't be read. The stored one is then untouched. Validators and
    ///   rewards are best effort, and unresolved transactions are checked either way.
    func load(_ account: Account, accountId: PersistentIdentifier) async throws {
        startReconciling(account, accountId: accountId)

        let startedAt = now()
        let stored = try await storedDetails(accountId)
        let read = try await source.read(for: account, known: stored?.positions.map(\.account.address) ?? [])

        try await save(read, stored: stored, account: account, accountId: accountId, startedAt: startedAt)
    }

    // MARK: Validators

    /// The votable validators, cached per network and endpoint. A failed lookup yields the
    /// last good list (or none) and never evicts it.
    func validators(for account: Account) async -> [SolanaValidator] {
        let key = "\((try? account.blockchain.asJSONString()) ?? "")|\(account.rpcURLOverride?.absoluteString ?? "")"
        let cached = cache[key]

        if let cached {
            let degraded = cached.list.allSatisfy { $0.name == nil && $0.apy == nil }
            let lifetime = degraded ? Self.degradedLifetime : Self.validatorsLifetime

            if now().timeIntervalSince(cached.fetchedAt) < lifetime {
                return cached.list
            }
        }

        let fetchedAt = now()

        guard let list = try? await source.validators(for: account) else {
            return cached?.list ?? []
        }

        cache[key] = CachedValidators(fetchedAt: fetchedAt, list: list)
        return list
    }

    // MARK: Recording

    /// Stores a read other code already fetched, which started at `startedAt`.
    func record(read: SolanaStakingRead, startedAt: Date, account: Account) async throws {
        guard let accountId = account.id else {
            throw ReefrError.invalidData
        }

        let stored = try await storedDetails(accountId)
        try await save(read, stored: stored, account: account, accountId: accountId, startedAt: startedAt)
    }

    // MARK: Pending submissions

    /// The account's unresolved transactions.
    func pendingSubmissions(accountId: PersistentIdentifier) async throws -> [SolanaPendingSubmission] {
        try await storedDetails(accountId)?.pendingSubmissions ?? []
    }

    /// The stake accounts stored for the account, for a read's fallback.
    func knownAddresses(accountId: PersistentIdentifier) async throws -> [String] {
        try await storedDetails(accountId)?.positions.map(\.account.address) ?? []
    }

    /// What the latest check of `signature` found, kept for an open sheet to show.
    func latestUpdate(for signature: String) -> SolanaSubmissionUpdate? {
        latestUpdates[signature]
    }

    /// Adds `submission` to the record. Throwing means it must not be broadcast.
    func addPending(_ submission: SolanaPendingSubmission, accountId: PersistentIdentifier) async throws {
        let pending = try await pendingSubmissions(accountId: accountId)

        try await databaseService.saveSolanaPendingSubmissions(
            accountId: accountId,
            submissions: pending + [submission]
        )
    }

    func removePending(signature: String, accountId: PersistentIdentifier) async throws {
        let pending = try await pendingSubmissions(accountId: accountId)

        try await databaseService.saveSolanaPendingSubmissions(
            accountId: accountId,
            submissions: pending.filter { $0.signature != signature }
        )
    }

    /// Checks every unresolved transaction once, waiting for a check already running.
    func reconcilePending(_ account: Account, accountId: PersistentIdentifier) async {
        startReconciling(account, accountId: accountId)
        await reconciling[accountId]?.value
    }
}

// MARK: - Private

private extension SolanaStakingPositionLoader {
    func storedDetails(_ accountId: PersistentIdentifier) async throws -> SolanaStakingDetails? {
        guard case let .solana(details)? = try await databaseService.fetchStaking(accountId: accountId)?.details else {
            return nil
        }

        return details
    }

    func save(
        _ read: SolanaStakingRead,
        stored: SolanaStakingDetails?,
        account: Account,
        accountId: PersistentIdentifier,
        startedAt: Date
    ) async throws {
        let retired = SolanaStakingDetails.retired(stored, read: read)
        let addresses = Set(read.accounts.map(\.address)).union(retired.keys)
        var rewards: SolanaStakingRewards?

        if read.clock.epoch > 0, !addresses.isEmpty, SolanaStakingDetails.needsRewards(
            stored: stored?.rewards,
            epoch: read.clock.epoch - 1,
            addresses: addresses,
            now: now()
        ) {
            rewards = try? await source.rewards(for: account, read: read, retired: Array(retired.keys))
        }

        let listed = await validators(for: account)
        let voters = Set(read.accounts.compactMap(\.delegation?.voter))
        let known = listed.filter { voters.contains($0.voteAddress) }.map {
            ($0.voteAddress, SolanaStakingDetails.Validator(commission: $0.commission, name: $0.name, apy: $0.apy))
        }

        try await databaseService.saveStakingState(
            accountId: accountId,
            observation: SolanaStakingObservation(
                read: read,
                rewards: rewards,
                validators: Dictionary(known, uniquingKeysWith: { first, _ in first })
            ),
            startedAt: startedAt
        )
    }

    /// A proof of expiry can take minutes on a rate-limited node, so this runs apart from reads.
    func startReconciling(_ account: Account, accountId: PersistentIdentifier) {
        guard reconciling[accountId] == nil else {
            return
        }

        reconciling[accountId] = Task {
            await RequestLane.$current.withValue(.balances) {
                await reconcileAll(account, accountId: accountId)
            }

            finishReconciling(accountId)
        }
    }

    func finishReconciling(_ accountId: PersistentIdentifier) {
        reconciling[accountId] = nil
    }

    func reconcileAll(_ account: Account, accountId: PersistentIdentifier) async {
        guard let pending = try? await pendingSubmissions(accountId: accountId), !pending.isEmpty else {
            return
        }

        var resolved = false

        for submission in pending {
            let update = await source.reconcile(submission, account: account) { [weak self] progress in
                await self?.replacePending(progress, accountId: accountId)
            }

            latestUpdates[submission.signature] = update

            switch update {
            case .confirmed, .expired, .failed:
                resolved = true

                do {
                    try await removePending(signature: submission.signature, accountId: accountId)
                } catch {
                    printError("\(account.name) staking: \(error)")
                }

            case let .unresolved(progress):
                await replacePending(progress, accountId: accountId)
            }
        }

        if resolved {
            await onResolved(account)
        }
    }

    func replacePending(_ submission: SolanaPendingSubmission, accountId: PersistentIdentifier) async {
        do {
            let pending = try await pendingSubmissions(accountId: accountId)

            guard
                pending.contains(where: { $0.signature == submission.signature }),
                !pending.contains(submission)
            else {
                return
            }

            try await databaseService.saveSolanaPendingSubmissions(
                accountId: accountId,
                submissions: pending.map { $0.signature == submission.signature ? submission : $0 }
            )
        } catch {
            printError("Solana staking: \(error)")
        }
    }
}
