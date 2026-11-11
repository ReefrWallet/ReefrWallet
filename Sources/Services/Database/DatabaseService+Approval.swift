//
//  DatabaseService+Approval.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 24.10.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation
import SwiftData

extension DatabaseService {
    func deleteApproval(id: PersistentIdentifier) throws {
        let predicate = #Predicate<ApprovalModel> { $0.persistentModelID == id }

        guard let approval = try modelContext.fetch(FetchDescriptor(predicate: predicate)).first else {
            return
        }

        modelContext.delete(approval)
        try modelContext.save()
    }

    func approvalCount(account: Account) throws -> Int {
        try modelContext.fetchCount(approvalDescriptor(for: account))
    }

    func fetchApprovals(account: Account) throws -> [TokenApproval] {
        try modelContext.fetch(approvalDescriptor(for: account)).map(TokenApproval.init(model:))
    }

    func fetchApprovalPage(account: Account, offset: Int, limit: Int) throws -> AccountPage<TokenApproval> {
        var descriptor = try approvalDescriptor(for: account)
        descriptor.fetchOffset = offset
        descriptor.fetchLimit = limit + 1
        let models = try modelContext.fetch(descriptor)
        return AccountPage(
            rows: models.prefix(limit).map(TokenApproval.init(model:)),
            hasMore: models.count > limit
        )
    }

    private func approvalDescriptor(for account: Account) throws -> FetchDescriptor<ApprovalModel> {
        guard let accountId = account.id else {
            throw ReefrError.invalidData
        }

        var descriptor = FetchDescriptor(
            predicate: #Predicate<ApprovalModel> { $0.account.persistentModelID == accountId },
            sortBy: [
                SortDescriptor(\.approvedAt, order: .reverse),
                SortDescriptor(\.spender),
                SortDescriptor(\.token.address)
            ]
        )

        descriptor.relationshipKeyPathsForPrefetching = [\.token]
        return descriptor
    }

    func fetchApprovalScans(account: Account) throws -> [String: ApprovalScanState] {
        guard let accountId = account.id else {
            throw ReefrError.invalidData
        }

        return try modelContext
            .fetch(FetchDescriptor(
                predicate: #Predicate<ApprovalScanModel> { $0.account.persistentModelID == accountId }
            ))
            .reduce(into: [:]) { result, model in
                result[model.tokenAddress] = ApprovalScanState(block: model.scannedBlock.map(UInt64.init))
            }
    }

    /// Makes `account`'s stored approvals match `updates`: upserts by (token, spender)
    /// and deletes the rest.
    func replaceApprovals(
        account: Account,
        updates: [ApprovalUpdate],
        scans: [String: ApprovalScanState] = [:]
    ) throws {
        guard let accountId = account.id else {
            throw ReefrError.invalidData
        }

        let accountPredicate = #Predicate<AccountModel> { $0.persistentModelID == accountId }

        guard let accountModel = try modelContext.fetch(FetchDescriptor(predicate: accountPredicate)).first else {
            throw ReefrError.notFound
        }

        let serializedBlockchain = try account.blockchain.asJSONString()
        let existing = try modelContext.fetch(FetchDescriptor(
            predicate: #Predicate<ApprovalModel> { $0.account.persistentModelID == accountId }
        ))

        let keyed = existing.map { (approvalKey($0.token.address, $0.spender), $0) }
        var remaining = Dictionary(keyed, uniquingKeysWith: { first, _ in first })
        var kept: Set<String> = []

        for update in updates {
            let key = approvalKey(update.token.address, update.spender)
            let tokenModel = try upsertTokenModel(update.token, serializedBlockchain: serializedBlockchain)

            if let model = remaining[key] {
                model.allowance = update.allowance
                model.approvedAt = update.approvedAt
            } else {
                modelContext.insert(ApprovalModel(
                    account: accountModel,
                    allowance: update.allowance,
                    approvedAt: update.approvedAt,
                    spender: update.spender,
                    token: tokenModel
                ))
            }

            kept.insert(key)
        }

        for (key, model) in remaining where !kept.contains(key) {
            modelContext.delete(model)
        }

        remaining.removeAll()

        // Same transaction as the approvals, so a cursor never gets ahead of the rows it covers.
        var scanModels = Dictionary(
            uniqueKeysWithValues: accountModel.approvalScans.map { ($0.tokenAddress, $0) }
        )

        for (tokenAddress, state) in scans {
            if let model = scanModels[tokenAddress] {
                model.scannedBlock = state.block.map(Int64.init)
            } else {
                let model = ApprovalScanModel(account: accountModel, state: state, tokenAddress: tokenAddress)
                modelContext.insert(model)
                scanModels[tokenAddress] = model
            }
        }

        try modelContext.save()
    }
}

private func approvalKey(_ tokenAddress: String?, _ spender: String) -> String {
    "\(tokenAddress?.lowercased() ?? "")-\(spender.lowercased())"
}
