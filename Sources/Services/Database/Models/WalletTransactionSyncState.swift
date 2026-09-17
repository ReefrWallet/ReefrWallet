//
//  WalletTransactionSyncState.swift
//  Reefr Wallet
//

import Foundation
import SwiftData

/// Durable, chain-opaque progress state for the two concurrent sync tracks.
struct WalletTransactionSyncState: Sendable {
    let accountId: PersistentIdentifier
    var initialBackfillHead: UInt64?
    var descendingCursor: Data?
    var ascendingCursor: Data?
    var currentHead: UInt64?
    var backfillComplete: Bool
    var historyBoundary: UInt64?
    var lastError: String?

    init(accountId: PersistentIdentifier) {
        self.accountId = accountId
        initialBackfillHead = nil
        descendingCursor = nil
        ascendingCursor = nil
        currentHead = nil
        backfillComplete = false
        historyBoundary = nil
        lastError = nil
    }

    init(model: WalletTransactionSyncStateModel) {
        accountId = model.account.id
        initialBackfillHead = model.initialBackfillHead
        descendingCursor = model.descendingCursor
        ascendingCursor = model.ascendingCursor
        currentHead = model.currentHead
        backfillComplete = model.backfillComplete
        historyBoundary = model.historyBoundary
        lastError = model.lastError
    }
}

@Model
final class WalletTransactionSyncStateModel {
    @Attribute(.unique) var accountStableID: String
    var initialBackfillHead: UInt64?
    var descendingCursor: Data?
    var ascendingCursor: Data?
    var currentHead: UInt64?
    var backfillComplete: Bool
    var historyBoundary: UInt64?
    var lastError: String?

    @Relationship(deleteRule: .noAction)
    var account: AccountModel

    init(account: AccountModel, state: WalletTransactionSyncState) {
        accountStableID = "\(account.id)"
        initialBackfillHead = state.initialBackfillHead
        descendingCursor = state.descendingCursor
        ascendingCursor = state.ascendingCursor
        currentHead = state.currentHead
        backfillComplete = state.backfillComplete
        historyBoundary = state.historyBoundary
        lastError = state.lastError
        self.account = account
    }
}
