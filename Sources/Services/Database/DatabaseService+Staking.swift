//
//  DatabaseService+Staking.swift
//  ReefrWallet
//
//  Created by Andrey Yurkevich on 06/11/2026.
//

import SwiftData
import WalletKit

extension DatabaseService {
    /// The stored position, or `nil` if there is none (or it was written by an incompatible version).
    func fetchStaking(accountId: PersistentIdentifier) throws -> Staking? {
        try modelContext
            .fetch(FetchDescriptor<StakingModel>(predicate: #Predicate { $0.account.persistentModelID == accountId }))
            .first
            .flatMap(Staking.init(model:))
    }

    /// Stores a full state read that started at `startedAt`, creating the account's position if it
    /// has none (its token is the chain's native one). Returns whether anything was applied;
    /// see ``Staking`` for the ordering rules.
    @discardableResult
    func saveStakingState(
        accountId: PersistentIdentifier,
        state: TronStakingState,
        representatives: [String: TronStakingDetails.Representative],
        startedAt: Date
    ) throws -> Bool {
        try saveStaking(accountId: accountId) { tokenId in
            Staking.tron(
                accountId: accountId,
                tokenId: tokenId,
                state: state,
                representatives: representatives,
                startedAt: startedAt
            )
        } update: { current in
            current.applying(state: state, representatives: representatives, startedAt: startedAt)
        }
    }

    /// Stores a Solana read that started at `startedAt`, like the Tron overload. Returns whether
    /// anything was applied.
    @discardableResult
    func saveStakingState(
        accountId: PersistentIdentifier,
        observation: SolanaStakingObservation,
        startedAt: Date
    ) throws -> Bool {
        try saveStaking(accountId: accountId) { tokenId in
            Staking.solana(accountId: accountId, tokenId: tokenId, observation: observation, startedAt: startedAt)
        } update: { current in
            current.applying(observation: observation, startedAt: startedAt)
        }
    }

    /// Stores a Sui read that started at `startedAt`, like the Tron overload. Returns whether anything
    /// was applied.
    @discardableResult
    func saveStakingState(
        accountId: PersistentIdentifier,
        read: SuiStakingRead,
        startedAt: Date
    ) throws -> Bool {
        try saveStaking(accountId: accountId) { tokenId in
            Staking.sui(accountId: accountId, tokenId: tokenId, read: read, startedAt: startedAt)
        } update: { current in
            current.applying(read: read, startedAt: startedAt)
        }
    }

    /// Records `submission` as the account's only unresolved Sui transaction, in one write.
    ///
    /// This is the claim a broadcast needs: the actor makes the check and the write indivisible, so two
    /// sends cannot both pass it.
    ///
    /// - Returns: `false` if another submission is still unresolved, in which case nothing is written.
    /// - Throws: ``ReefrError/notFound`` if the account has no position to hold it. A caller about to
    ///   broadcast must not go on: the record has to exist first.
    func claimSuiSubmission(accountId: PersistentIdentifier, submission: SuiPendingSubmission) throws -> Bool {
        let account = try fetchAccountModel(id: accountId)

        guard let model = account.staking, let current = Staking(model: model), case .sui = current.details else {
            throw ReefrError.notFound
        }

        guard let claimed = current.claiming(submission) else {
            return false
        }

        try model.update(from: claimed)
        try modelContext.save()
        return true
    }

    /// Records the history placeholder for the Sui transaction `digest`, only while it is still pending.
    ///
    /// The check and the write happen in one actor call, so a send whose response arrives after
    /// reconciliation proved it expired and cleared the claim cannot bring the placeholder back.
    ///
    /// - Returns: whether the placeholder was recorded.
    @discardableResult
    func recordSuiBroadcast(digest: String, for account: Account) throws -> Bool {
        guard
            let accountId = account.id,
            case let .sui(details)? = try fetchStaking(accountId: accountId)?.details,
            details.pendingSubmissions.contains(where: { $0.digest == digest })
        else {
            return false
        }

        try saveTransactions([BlockchainTransaction(identifier: digest, status: .broadcast)], for: account)
        return true
    }

    /// Clears a Sui submission proven never to have run: its claim and its history placeholder, in one save.
    ///
    /// A late send response cannot slip between the two: the placeholder is only ever written while the claim
    /// exists, and both are gone together. A confirmed or failed history row is never touched.
    func clearNonExecutedSuiSubmission(digest: String, for account: Account) throws {
        guard let accountId = account.id else {
            throw ReefrError.invalidData
        }

        let accountModel = try fetchAccountModel(id: accountId)

        let model = accountModel.staking
        let updated = model.flatMap(Staking.init(model:)).flatMap { Self.removing(digest, from: $0) }

        do {
            if let model, let updated {
                try model.update(from: updated)
            }

            _ = try deleteBroadcastPlaceholder(identifier: digest, for: account)
            try modelContext.save()
        } catch {
            // Otherwise a later save could persist the claim's removal alone.
            modelContext.rollback()
            throw error
        }
    }

    /// `staking` without the pending Sui submission `digest`; `nil` if it isn't pending (or isn't Sui).
    private static func removing(_ digest: String, from staking: Staking) -> Staking? {
        guard
            case let .sui(details) = staking.details,
            details.pendingSubmissions.contains(where: { $0.digest == digest })
        else {
            return nil
        }

        return staking.applying(pendingSubmissions: details.pendingSubmissions.filter { $0.digest != digest })
    }

    /// Removes the pending Sui submission `digest`, checking and writing in one actor call. Two resolvers
    /// racing for the same digest cannot erase a submission claimed in between: the second finds it gone.
    ///
    /// - Returns: whether it was still there.
    @discardableResult
    func removeSuiSubmission(accountId: PersistentIdentifier, digest: String) throws -> Bool {
        let account = try fetchAccountModel(id: accountId)

        guard
            let model = account.staking,
            let current = Staking(model: model),
            let updated = Self.removing(digest, from: current)
        else {
            return false
        }

        try model.update(from: updated)
        try modelContext.save()
        return true
    }

    /// Replaces the account's pending Sui submissions.
    ///
    /// - Throws: ``ReefrError/notFound`` if the account has no position to hold them.
    func saveSuiPendingSubmissions(
        accountId: PersistentIdentifier,
        submissions: [SuiPendingSubmission]
    ) throws {
        try updateStored(accountId: accountId) { $0.applying(pendingSubmissions: submissions) }
    }

    /// Stores a Cardano read that started at `startedAt`, like the Tron overload. Returns whether
    /// anything was applied.
    @discardableResult
    func saveStakingState(
        accountId: PersistentIdentifier,
        observation: CardanoStakingObservation,
        startedAt: Date
    ) throws -> Bool {
        try saveStaking(accountId: accountId) { tokenId in
            Staking.cardano(accountId: accountId, tokenId: tokenId, observation: observation, startedAt: startedAt)
        } update: { current in
            current.applying(observation: observation, startedAt: startedAt)
        }
    }

    /// Replaces the account's pending Cardano submissions.
    ///
    /// - Throws: ``ReefrError/notFound`` if the account has no position to hold them. A caller
    ///   about to broadcast must not go on: the record has to exist first.
    func saveCardanoPendingSubmissions(
        accountId: PersistentIdentifier,
        submissions: [CardanoPendingSubmission]
    ) throws {
        try updateStored(accountId: accountId) { $0.applying(pendingSubmissions: submissions) }
    }

    /// Removes the pending Cardano submission `hash` and changes the workflow in one write.
    func resolveCardanoSubmission(
        accountId: PersistentIdentifier,
        hash: String,
        workflow change: (CardanoStakingWorkflow?) -> CardanoStakingWorkflow?
    ) throws {
        try updateStored(accountId: accountId) { $0.applying(resolved: hash, workflow: change) }
    }

    /// Replaces the account's Cardano workflow; `nil` clears it.
    ///
    /// - Throws: ``ReefrError/notFound`` if the account has no position to hold it.
    func saveCardanoWorkflow(accountId: PersistentIdentifier, workflow: CardanoStakingWorkflow?) throws {
        try updateStored(accountId: accountId) { $0.applying(workflow: workflow) }
    }

    /// Replaces the account's pending Solana submissions.
    ///
    /// - Throws: ``ReefrError/notFound`` if the account has no position to hold them. A caller
    ///   about to broadcast must not go on: the record has to exist first.
    func saveSolanaPendingSubmissions(
        accountId: PersistentIdentifier,
        submissions: [SolanaPendingSubmission]
    ) throws {
        let account = try fetchAccountModel(id: accountId)

        guard
            let model = account.staking,
            let updated = Staking(model: model)?.applying(pendingSubmissions: submissions)
        else {
            throw ReefrError.notFound
        }

        try model.update(from: updated)
        try modelContext.save()
    }

    /// Stores bandwidth and energy from a read that started at `startedAt`. Returns whether they
    /// were applied: not when the account has no position yet, or has newer allowances.
    @discardableResult
    func saveStakingResources(
        accountId: PersistentIdentifier,
        resources: TronResourceUsage,
        startedAt: Date
    ) throws -> Bool {
        let account = try fetchAccountModel(id: accountId)

        guard
            let model = account.staking,
            let updated = Staking(model: model)?.applying(resources: resources, startedAt: startedAt)
        else {
            return false
        }

        try model.update(from: updated)
        try modelContext.save()
        return true
    }
}

private extension DatabaseService {
    func updateStored(accountId: PersistentIdentifier, _ change: (Staking) -> Staking?) throws {
        let account = try fetchAccountModel(id: accountId)

        guard let model = account.staking, let updated = Staking(model: model).flatMap(change) else {
            throw ReefrError.notFound
        }

        try model.update(from: updated)
        try modelContext.save()
    }

    func fetchAccountModel(id: PersistentIdentifier) throws -> AccountModel {
        let predicate = #Predicate<AccountModel> { $0.persistentModelID == id }

        guard let account = try modelContext.fetch(FetchDescriptor(predicate: predicate)).first else {
            throw ReefrError.notFound
        }

        return account
    }

    /// Creates the account's row (or overwrites one that can't be read), or applies `update`
    /// to the stored position; `update` returning `nil` means nothing in it is newer.
    func saveStaking(
        accountId: PersistentIdentifier,
        create: (PersistentIdentifier) -> Staking,
        update: (Staking) -> Staking?
    ) throws -> Bool {
        let account = try fetchAccountModel(id: accountId)

        guard let model = account.staking, let current = Staking(model: model) else {
            let token = account.blockchain.nativeToken
            let staking = create(token.persistentModelID)

            if let model = account.staking {
                try model.update(from: staking)
            } else {
                let model = try StakingModel(account: account, token: token, staking: staking)
                account.staking = model
                modelContext.insert(model)
            }

            try modelContext.save()
            return true
        }

        guard let updated = update(current) else {
            return false
        }

        try model.update(from: updated)
        try modelContext.save()
        return true
    }
}
