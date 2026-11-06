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
        let account = try fetchAccountModel(id: accountId)

        guard let model = account.staking, let current = Staking(model: model) else {
            let token = account.blockchain.nativeToken
            let staking = Staking.tron(
                accountId: accountId,
                tokenId: token.persistentModelID,
                state: state,
                representatives: representatives,
                startedAt: startedAt
            )

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

        let observation = current.applying(state: state, representatives: representatives, startedAt: startedAt)

        guard let updated = observation else {
            return false
        }

        try model.update(from: updated)
        try modelContext.save()
        return true
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
}
