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
