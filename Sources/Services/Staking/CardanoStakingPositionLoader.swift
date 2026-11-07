//
//  CardanoStakingPositionLoader.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 08.11.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation
import SwiftData
import WalletKit

// MARK: - CardanoStakingSource

/// Where a Cardano account's staking state is read from and its transactions go.
protocol CardanoStakingSource: Sendable {
    func availableBalance(for account: Account) async throws -> BigUInt
    func broadcast(_ prepared: CardanoPreparedStaking, signed: Data, account: Account) async throws -> String
    func drep(_ id: String, account: Account) async throws -> CardanoDRepInfo?
    func pool(_ id: String, account: Account) async throws -> CardanoPool?
    func pools(account: Account) async throws -> [CardanoPool]
    func prepare(
        _ action: CardanoStakingAction,
        read: CardanoStakingRead,
        account: Account
    ) async throws -> CardanoPreparedStaking
    func read(for account: Account) async throws -> CardanoStakingRead
    func secondsRemaining(ttl: UInt64, account: Account) async throws -> Int64
    func sign(_ prepared: CardanoPreparedStaking, account: Account) async throws -> Data
    func submissionState(_ pending: CardanoPendingSubmission, account: Account) async throws -> CardanoSubmissionState
}

struct CardanoNodeStakingSource: CardanoStakingSource {
    private func client(_ account: Account) throws -> CardanoClient {
        guard
            case .cardano = account.blockchain,
            let client = try DI.injectOrFail(BlockchainClientProvider.self)
                .makeClient(blockchain: account.blockchain, rpcURL: account.rpcURLOverride) as? CardanoClient
        else {
            throw ReefrError.invalidData
        }

        return client
    }

    private func owner(_ account: Account) throws -> CardanoAccountDescriptor {
        try CardanoAccountDescriptor(string: account.address)
    }

    func availableBalance(for account: Account) async throws -> BigUInt {
        try await client(account).signableLovelace(owner(account))
    }

    func broadcast(_ prepared: CardanoPreparedStaking, signed: Data, account: Account) async throws -> String {
        try await DI.injectOrFail(TransactionService.self)
            .sendTransaction(prepared.envelope(), signed, account: account)
    }

    func drep(_ id: String, account: Account) async throws -> CardanoDRepInfo? {
        try await client(account).drep(id)
    }

    func pool(_ id: String, account: Account) async throws -> CardanoPool? {
        try await client(account).pool(id)
    }

    func pools(account: Account) async throws -> [CardanoPool] {
        try await client(account).pools()
    }

    func prepare(
        _ action: CardanoStakingAction,
        read: CardanoStakingRead,
        account: Account
    ) async throws -> CardanoPreparedStaking {
        try await client(account).prepareStaking(owner(account), action: action, read: read)
    }

    func read(for account: Account) async throws -> CardanoStakingRead {
        try await client(account).stakingRead(owner(account))
    }

    func secondsRemaining(ttl: UInt64, account: Account) async throws -> Int64 {
        try await client(account).secondsRemaining(ttl: ttl)
    }

    func sign(_ prepared: CardanoPreparedStaking, account: Account) async throws -> Data {
        try await DI.injectOrFail(TransactionService.self).signTransaction(prepared.envelope(), account: account)
    }

    func submissionState(
        _ pending: CardanoPendingSubmission,
        account: Account
    ) async throws -> CardanoSubmissionState {
        try await client(account).submissionState(pending)
    }
}

// MARK: - CardanoStakingPositionLoader

/// Stores the staking position of Cardano accounts, reconciles their unresolved transactions and
/// advances their two-step workflows. See ADR-059.
actor CardanoStakingPositionLoader: StakingPositionLoading {
    private let databaseService: DatabaseService
    private let onResolved: @Sendable (Account) async -> Void
    private let source: any CardanoStakingSource

    private var reconciling: [PersistentIdentifier: Task<Void, Never>] = [:]

    /// - Parameter onResolved: Runs after a submission resolves, for what it changed: by default
    ///   the position and spendable balance, whichever way it resolved (a fee may have been paid).
    init(
        databaseService: DatabaseService? = nil,
        source: (any CardanoStakingSource)? = nil,
        onResolved: (@Sendable (Account) async -> Void)? = nil
    ) {
        self.databaseService = databaseService ?? DI.injectOrFail(DatabaseService.self)
        self.onResolved = onResolved ?? { account in
            async let position: Void? = try? DI.injectOrFail(StakingStateService.self).refreshAfterChange(account)
            try? await DI.injectOrFail(BalancesService.self).updateBalances(account, includeStaking: false)
            _ = await position
        }

        self.source = source ?? CardanoNodeStakingSource()
    }

    // MARK: StakingPositionLoading

    nonisolated func supports(_ blockchain: Blockchain) -> Bool {
        if case .cardano = blockchain {
            true
        } else {
            false
        }
    }

    /// - Throws: if the position can't be read. The stored one is then untouched. Pool and DRep
    ///   names are best effort, and unresolved transactions are checked either way.
    func load(_ account: Account, accountId: PersistentIdentifier) async throws {
        startReconciling(account, accountId: accountId)

        let startedAt = Date()
        let read = try await source.read(for: account)

        try await save(read, account: account, accountId: accountId, startedAt: startedAt)
    }

    // MARK: Recording

    /// Stores a read other code already fetched, which started at `startedAt`.
    func record(read: CardanoStakingRead, startedAt: Date, account: Account) async throws {
        guard let accountId = account.id else {
            throw ReefrError.invalidData
        }

        try await save(read, account: account, accountId: accountId, startedAt: startedAt)
    }

    // MARK: Pending submissions and workflow

    func pendingSubmissions(accountId: PersistentIdentifier) async throws -> [CardanoPendingSubmission] {
        try await storedDetails(accountId)?.pendingSubmissions ?? []
    }

    func workflow(accountId: PersistentIdentifier) async throws -> CardanoStakingWorkflow? {
        try await storedDetails(accountId)?.workflow
    }

    /// Adds `submission` to the record. Throwing means it must not be broadcast.
    func addPending(_ submission: CardanoPendingSubmission, accountId: PersistentIdentifier) async throws {
        let pending = try await pendingSubmissions(accountId: accountId)

        try await databaseService.saveCardanoPendingSubmissions(
            accountId: accountId,
            submissions: pending + [submission]
        )
    }

    func removePending(hash: String, accountId: PersistentIdentifier) async throws {
        let pending = try await pendingSubmissions(accountId: accountId)

        try await databaseService.saveCardanoPendingSubmissions(
            accountId: accountId,
            submissions: pending.filter { $0.hash != hash }
        )
    }

    /// Removes the pending submission `hash` and changes the workflow in one write.
    func resolve(
        hash: String,
        accountId: PersistentIdentifier,
        workflow change: (CardanoStakingWorkflow?) -> CardanoStakingWorkflow?
    ) async throws {
        try await databaseService.resolveCardanoSubmission(accountId: accountId, hash: hash, workflow: change)
    }

    /// Replaces the workflow; `nil` clears it. Throwing means the step must not go on.
    func setWorkflow(_ workflow: CardanoStakingWorkflow?, accountId: PersistentIdentifier) async throws {
        try await databaseService.saveCardanoWorkflow(accountId: accountId, workflow: workflow)
    }

    /// Checks every unresolved transaction once, waiting for a check already running.
    func reconcilePending(_ account: Account, accountId: PersistentIdentifier) async {
        startReconciling(account, accountId: accountId)
        await reconciling[accountId]?.value
    }

    /// What resolving the submission `hash` did to the workflow, which is changed
    /// only if it was waiting on that submission. A confirmed first step is promoted by the
    /// next read that shows its DRep, in ``promoted(_:read:pending:)``.
    nonisolated static func resolved(
        _ workflow: CardanoStakingWorkflow?,
        hash: String,
        state: CardanoSubmissionState,
        at date: Date = Date()
    ) -> CardanoStakingWorkflow? {
        guard var workflow else {
            return nil
        }

        switch (workflow.phase, state) {
        case (.voteDelegationPending(hash), .expired):
            workflow.phase = .needsVoteDelegation(notice: .expired)
        case (.finalStepPending(hash), .confirmed):
            return nil
        case (.finalStepPending(hash), .expired):
            workflow.phase = .readyForFinalStep(notice: .expired)
        default:
            return workflow
        }

        workflow.updatedAt = date
        return workflow
    }

    /// A step-1 workflow once its submission has resolved and the live `read` shows the DRep.
    nonisolated static func promoted(
        _ workflow: CardanoStakingWorkflow?,
        read: CardanoStakingRead,
        pending: [CardanoPendingSubmission],
        at date: Date = Date()
    ) -> CardanoStakingWorkflow? {
        guard
            var workflow,
            case let .voteDelegationPending(hash) = workflow.phase,
            !pending.contains(where: { $0.hash == hash }),
            read.drep == workflow.drep
        else {
            return workflow
        }

        workflow.phase = .readyForFinalStep(notice: nil)
        workflow.updatedAt = date
        return workflow
    }
}

// MARK: - Private

private extension CardanoStakingPositionLoader {
    func storedDetails(_ accountId: PersistentIdentifier) async throws -> CardanoStakingDetails? {
        guard case let .cardano(details)? = try await databaseService.fetchStaking(accountId: accountId)?.details else {
            return nil
        }

        return details
    }

    func save(
        _ read: CardanoStakingRead,
        account: Account,
        accountId: PersistentIdentifier,
        startedAt: Date
    ) async throws {
        async let pool = pool(read.poolId, account: account)
        async let drepName = drepName(read.drep, account: account)

        try await databaseService.saveStakingState(
            accountId: accountId,
            observation: CardanoStakingObservation(read: read, drepName: await drepName, pool: await pool),
            startedAt: startedAt
        )

        try? await promoteWorkflow(read: read, accountId: accountId)
    }

    func pool(_ id: String?, account: Account) async -> CardanoPool? {
        guard let id else {
            return nil
        }

        return (try? await source.pool(id, account: account)) ?? nil
    }

    func drepName(_ drep: CardanoDRep?, account: Account) async -> String? {
        guard case let .id(id)? = drep else {
            return nil
        }

        return (try? await source.drep(id, account: account))?.name
    }

    func promoteWorkflow(read: CardanoStakingRead, accountId: PersistentIdentifier) async throws {
        guard let stored = try await storedDetails(accountId), let workflow = stored.workflow else {
            return
        }

        let promoted = Self.promoted(workflow, read: read, pending: stored.pendingSubmissions)

        if promoted != workflow {
            try await setWorkflow(promoted, accountId: accountId)
        }
    }

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
            guard let state = try? await source.submissionState(submission, account: account), state != .pending else {
                continue
            }

            resolved = true

            do {
                try await resolve(hash: submission.hash, accountId: accountId) {
                    Self.resolved($0, hash: submission.hash, state: state)
                }
            } catch {
                printError("\(account.name) staking: \(error)")
            }
        }

        if resolved {
            await onResolved(account)
        }
    }
}
