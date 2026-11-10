//
//  WalletTransactionSyncState.swift
//  Reefr Wallet
//

import Foundation
import SwiftData

/// Durable, chain-opaque progress state for the two concurrent sync tracks.
struct WalletTransactionSyncState: Equatable, Sendable {
    let accountId: PersistentIdentifier
    var initialBackfillHead: UInt64?
    var descendingCursor: Data?
    var ascendingCursor: Data?
    var currentHead: UInt64?
    var backfillComplete: Bool
    var historyBoundary: UInt64?
    var lastError: String?
    /// `1` once the account's ERC-20 transfers are fully backfilled. Accounts synced before
    /// that backfill existed read `0` and get one resumable pass (ADR-065).
    var tokenBackfillVersion: Int
    var tokenBackfillCursor: Data?

    init(accountId: PersistentIdentifier) {
        self.accountId = accountId
        initialBackfillHead = nil
        descendingCursor = nil
        ascendingCursor = nil
        currentHead = nil
        backfillComplete = false
        historyBoundary = nil
        lastError = nil
        tokenBackfillVersion = 0
        tokenBackfillCursor = nil
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
        tokenBackfillVersion = model.tokenBackfillVersion
        tokenBackfillCursor = model.tokenBackfillCursor
    }
}

@Model
final class WalletTransactionSyncStateModel {
    @Attribute(.unique) var accountStableId: String
    var initialBackfillHead: UInt64?
    var descendingCursor: Data?
    var ascendingCursor: Data?
    var currentHead: UInt64?
    var backfillComplete: Bool
    var historyBoundary: UInt64?
    var lastError: String?
    var tokenBackfillVersion: Int = 0
    var tokenBackfillCursor: Data?

    @Relationship(deleteRule: .noAction)
    var account: AccountModel

    init(account: AccountModel, state: WalletTransactionSyncState) {
        accountStableId = "\(account.id)"
        initialBackfillHead = state.initialBackfillHead
        descendingCursor = state.descendingCursor
        ascendingCursor = state.ascendingCursor
        currentHead = state.currentHead
        backfillComplete = state.backfillComplete
        historyBoundary = state.historyBoundary
        lastError = state.lastError
        tokenBackfillVersion = state.tokenBackfillVersion
        tokenBackfillCursor = state.tokenBackfillCursor
        self.account = account
    }
}
