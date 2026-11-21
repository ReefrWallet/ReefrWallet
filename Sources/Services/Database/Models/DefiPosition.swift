//
//  DefiPosition.swift
//  Reefr Wallet
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation
import SwiftData

// MARK: - DefiPosition

/// A DeFi widget's stored state, written by its plugin. See ADR-073.
struct DefiPosition: Equatable, Identifiable, Sendable {
    let id: String
    let isUSDValueComplete: Bool
    /// The plugin-defined key, unique per account and kind.
    let key: String
    let kind: DefiPluginKind
    /// The plugin's own `Codable` model.
    let payload: Data
    let updatedAt: Date
    /// The sum of the position's priced parts.
    let usdValue: Decimal?

    init?(model: DefiPositionModel) {
        guard let kind = DefiPluginKind(rawValue: model.serializedKind) else {
            return nil
        }

        id = model.defiPositionId
        isUSDValueComplete = model.isUSDValueComplete
        key = model.key
        self.kind = kind
        payload = model.payload
        updatedAt = model.updatedAt
        usdValue = model.usdValue
    }

    init(
        id: String,
        isUSDValueComplete: Bool,
        key: String,
        kind: DefiPluginKind,
        payload: Data,
        updatedAt: Date,
        usdValue: Decimal?
    ) {
        self.id = id
        self.isUSDValueComplete = isUSDValueComplete
        self.key = key
        self.kind = kind
        self.payload = payload
        self.updatedAt = updatedAt
        self.usdValue = usdValue
    }

    static func makeId(kind: DefiPluginKind, accountKey: String, key: String) -> String {
        [kind.rawValue, accountKey, key].joined(separator: "|")
    }
}

// MARK: - DefiPositionModel

@Model
final class DefiPositionModel {
    @Attribute(.unique) var defiPositionId: String
    var isUSDValueComplete: Bool
    var key: String
    var payload: Data
    var serializedKind: String
    var updatedAt: Date
    var usdValue: Decimal?

    @Relationship(deleteRule: .noAction)
    var account: AccountModel

    init(
        account: AccountModel,
        defiPositionId: String,
        kind: DefiPluginKind,
        record: DefiPositionRecord,
        updatedAt: Date
    ) {
        self.account = account
        self.defiPositionId = defiPositionId
        isUSDValueComplete = record.isUSDValueComplete
        key = record.key
        payload = record.payload
        serializedKind = kind.rawValue
        self.updatedAt = updatedAt
        usdValue = record.usdValue
    }

    func update(from record: DefiPositionRecord, updatedAt: Date) {
        isUSDValueComplete = record.isUSDValueComplete
        payload = record.payload
        self.updatedAt = updatedAt
        usdValue = record.usdValue
    }
}
