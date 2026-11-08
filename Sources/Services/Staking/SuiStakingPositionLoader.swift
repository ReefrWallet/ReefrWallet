//
//  SuiStakingPositionLoader.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 08.11.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation
import SwiftData
import WalletKit

// MARK: - SuiStakingSource

/// Where a Sui account's stake is read from and its transactions go.
protocol SuiStakingSource: Sendable {
    func broadcast(
        _ submission: SuiPendingSubmission,
        isOriginalSend: Bool,
        account: Account
    ) async -> SuiBroadcastResult
    /// Clears a transaction proven never to have run: its pending claim and its history placeholder, together.
    /// This is the only way a non-executed submission is removed; if it throws, the claim stays for a retry.
    func clearNonExecuted(digest: String, account: Account) async throws
    func liquidBalance(for account: Account) async throws -> UInt64
    func prepare(_ action: SuiStakingAction, account: Account) async throws -> SuiPreparedStaking
    func read(for account: Account) async throws -> SuiStakingRead
    /// Records the history placeholder for a sent transaction, only while its submission is still pending.
    func recordBroadcast(digest: String, account: Account) async
    func resolve(_ submission: SuiPendingSubmission, account: Account) async -> SuiSubmissionResolution
    func sign(_ prepared: SuiPreparedStaking, account: Account) async throws -> Data
    func validators(for account: Account) async throws -> [SuiValidator]
}

struct SuiNodeStakingSource: SuiStakingSource {
    private func client(_ account: Account) throws -> SuiGRPCClient {
        try DI.injectOrFail(BlockchainClientProvider.self).suiClient(for: account)
    }

    func broadcast(
        _ submission: SuiPendingSubmission,
        isOriginalSend: Bool,
        account: Account
    ) async -> SuiBroadcastResult {
        guard let client = try? client(account) else {
            return .keepPending
        }

        return await SuiSubmissionResolver(chain: client)
            .broadcast(submission, isOriginalSendInThisProcess: isOriginalSend)
    }

    func clearNonExecuted(digest: String, account: Account) async throws {
        try await DI.injectOrFail(TransactionSyncService.self)
            .clearNonExecutedSuiSubmission(digest: digest, account: account)
    }

    /// Only owned coin objects: that is all preparation can spend, so the amount shown matches it.
    func liquidBalance(for account: Account) async throws -> UInt64 {
        try await client(account).suiCoins(of: SuiAddress(string: account.address)).map(\.balance).saturatingSum
    }

    func prepare(_ action: SuiStakingAction, account: Account) async throws -> SuiPreparedStaking {
        let owner = try SuiAddress(string: account.address)
        return try await SuiStakingPreparation(chain: client(account)).prepare(action, owner: owner)
    }

    func read(for account: Account) async throws -> SuiStakingRead {
        try await client(account).stakingRead(of: SuiAddress(string: account.address))
    }

    func recordBroadcast(digest: String, account: Account) async {
        await DI.injectOrFail(TransactionSyncService.self).recordPendingSuiBroadcast(digest: digest, account: account)
    }

    func resolve(_ submission: SuiPendingSubmission, account: Account) async -> SuiSubmissionResolution {
        guard let client = try? client(account) else {
            return .unresolved(.nodeUnavailable)
        }

        return await SuiSubmissionResolver(chain: client).resolve(submission)
    }

    func sign(_ prepared: SuiPreparedStaking, account: Account) async throws -> Data {
        try await DI.injectOrFail(TransactionService.self).signTransaction(prepared.transactionData, account: account)
    }

    func validators(for account: Account) async throws -> [SuiValidator] {
        try await client(account).stakingSystemState().validators
    }
}

// MARK: - SuiStakingPositionLoader

/// Stores the stake receipts of Sui accounts and reconciles their unresolved transactions.
/// See ADR-060 for what a read may replace and how a submission is resolved.
actor SuiStakingPositionLoader: StakingPositionLoading {
    private struct CachedValidators {
        let fetchedAt: Date
        let list: [SuiValidator]
    }

    private static let validatorsLifetime: TimeInterval = 300

    private let databaseService: DatabaseService
    private let now: @Sendable () -> Date
    private let onResolved: @Sendable (Account) async -> Void
    private let source: any SuiStakingSource

    private var cache: [String: CachedValidators] = [:]
    private var latestUpdates: [String: SuiSubmissionResolution] = [:]
    private var reconciling: [PersistentIdentifier: Task<Void, Never>] = [:]

    /// - Parameter onResolved: Runs after a submission resolves, for what it changed: by default the
    ///   position and spendable balance, also after a failure, which still cost gas.
    init(
        databaseService: DatabaseService? = nil,
        source: (any SuiStakingSource)? = nil,
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

        self.source = source ?? SuiNodeStakingSource()
    }

    // MARK: StakingPositionLoading

    nonisolated func supports(_ blockchain: Blockchain) -> Bool {
        if case .sui = blockchain {
            true
        } else {
            false
        }
    }

    /// - Throws: if the position can't be read. The stored one is then untouched. Unresolved
    ///   transactions are checked either way.
    func load(_ account: Account, accountId: PersistentIdentifier) async throws {
        startReconciling(account, accountId: accountId)

        let startedAt = now()
        let read = try await source.read(for: account)

        try await databaseService.saveStakingState(accountId: accountId, read: read, startedAt: startedAt)
    }

    // MARK: Validators

    /// The active validators, cached per network and endpoint. A failed lookup yields the last good
    /// list (or none) and never evicts it.
    func validators(for account: Account) async -> [SuiValidator] {
        let key = "\((try? account.blockchain.asJSONString()) ?? "")|\(account.rpcURLOverride?.absoluteString ?? "")"

        if let cached = cache[key], now().timeIntervalSince(cached.fetchedAt) < Self.validatorsLifetime {
            return cached.list
        }

        let fetchedAt = now()

        guard let list = try? await source.validators(for: account) else {
            return cache[key]?.list ?? []
        }

        let sorted = list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        cache[key] = CachedValidators(fetchedAt: fetchedAt, list: sorted)
        return sorted
    }

    // MARK: Recording

    /// Stores a read other code already fetched, which started at `startedAt`.
    func record(read: SuiStakingRead, startedAt: Date, account: Account) async throws {
        guard let accountId = account.id else {
            throw ReefrError.invalidData
        }

        try await databaseService.saveStakingState(accountId: accountId, read: read, startedAt: startedAt)
    }

    // MARK: Pending submissions

    /// The account's unresolved transactions.
    func pendingSubmissions(accountId: PersistentIdentifier) async throws -> [SuiPendingSubmission] {
        guard case let .sui(details)? = try await databaseService.fetchStaking(accountId: accountId)?.details else {
            return []
        }

        return details.pendingSubmissions
    }

    /// What the latest check of the transaction `digest` found, kept for an open sheet to show.
    func latestUpdate(for digest: String) -> SuiSubmissionResolution? {
        latestUpdates[digest]
    }

    /// Records `submission` as the account's only unresolved transaction, indivisibly.
    ///
    /// - Returns: `false` if another one is unresolved; nothing was written and nothing may be broadcast.
    /// - Throws: if it can't be recorded; it then must not be broadcast either.
    func claim(_ submission: SuiPendingSubmission, accountId: PersistentIdentifier) async throws -> Bool {
        try await databaseService.claimSuiSubmission(accountId: accountId, submission: submission)
    }

    /// Removes the submission `digest` in one write; one already cleared is left alone.
    func removePending(digest: String, accountId: PersistentIdentifier) async throws {
        try await databaseService.removeSuiSubmission(accountId: accountId, digest: digest)
    }

    /// Checks every unresolved transaction once, waiting for a check already running. With `rebroadcast`,
    /// one still within its validity window is first sent again, byte for byte: a node that already has
    /// it treats that as the same transaction.
    func reconcilePending(_ account: Account, accountId: PersistentIdentifier, rebroadcast: Bool = false) async {
        if rebroadcast, let pending = try? await pendingSubmissions(accountId: accountId) {
            for submission in pending {
                if case .unresolved(.stillValid) = await source.resolve(submission, account: account) {
                    _ = await source.broadcast(submission, isOriginalSend: false, account: account)
                }
            }
        }

        startReconciling(account, accountId: accountId)
        await reconciling[accountId]?.value
    }
}

// MARK: - Private

private extension SuiStakingPositionLoader {
    /// A proof of expiry can take several requests, so this runs apart from reads.
    func startReconciling(_ account: Account, accountId: PersistentIdentifier) {
        guard reconciling[accountId] == nil else {
            return
        }

        reconciling[accountId] = Task {
            await reconcileAll(account, accountId: accountId)
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
            let resolution = await source.resolve(submission, account: account)
            latestUpdates[submission.digest] = resolution

            if case .unresolved = resolution {
                continue
            }

            do {
                if case .notExecuted = resolution {
                    // Claim and history placeholder go in one save, and this is the only removal: if it
                    // fails the claim stays, so the next reconciliation retries both.
                    try await source.clearNonExecuted(digest: submission.digest, account: account)
                } else {
                    try await removePending(digest: submission.digest, accountId: accountId)
                }

                resolved = true
            } catch {
                printError("\(account.name) staking: \(error)")
            }
        }

        if resolved {
            await onResolved(account)
        }
    }
}
