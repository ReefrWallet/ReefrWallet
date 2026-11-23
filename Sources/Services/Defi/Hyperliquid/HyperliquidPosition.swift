//
//  HyperliquidPosition.swift
//  Reefr Wallet
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation

/// The stored payload of an account's HyperCore valuation. See ADR-074.
struct HyperliquidPosition: Codable, Equatable, Sendable {
    /// USD parts of Portfolio Value; `nil` where unpriced.
    struct Breakdown: Codable, Equatable, Sendable {
        let borrowed: Decimal?
        let lent: Decimal?
        let perps: Decimal?
        let spot: Decimal
        let staked: Decimal?
        let vaults: Decimal
    }

    struct Metric: Codable, Equatable, Sendable {
        enum State: String, Codable, Sendable {
            case complete
            /// Only nonnegative parts are unpriced: `usd` is a minimum.
            case lowerBound
            /// A part that could be negative is unpriced.
            case partial
            /// The account mode has no verified formula.
            case unavailable
        }

        let state: State
        let usd: Decimal?
    }

    let breakdown: Breakdown
    let mode: String
    let network: HyperliquidNetwork
    let openPositionCount: Int
    let portfolioValue: Metric
    /// Spot holdings without a USD price.
    let unpricedCoins: [String]
    let unrealizedPnl: Metric

    static let recordKey = "account"

    /// The stored record: Portfolio Value, or 0 when unknown; testnet values never reach real-dollar totals.
    var record: DefiPositionRecord {
        get throws {
            let usdValue = network == .mainnet && portfolioValue.state != .unavailable ? portfolioValue.usd : nil
            return try DefiPositionRecord(key: Self.recordKey, payload: encoded(), usdValue: usdValue ?? 0)
        }
    }
}
