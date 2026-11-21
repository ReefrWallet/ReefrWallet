//
//  UniswapV3Position.swift
//  Reefr Wallet
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation

/// The stored payload of one Uniswap V3 LP position. See ADR-073.
struct UniswapV3Position: Codable, Equatable, Sendable {
    /// Lifetime fees since mint at current prices ÷ deployed value ÷ age, as a fraction.
    let apr: Decimal?
    let chainId: UInt64
    let createdAt: Date?
    /// Token amounts currently providing liquidity.
    let deployed: Amounts
    let deployedUSD: Decimal?
    /// The pool fee in hundredths of a basis point (500 = 0.05%).
    let fee: UInt32
    /// The Fees column: exact accrued fees; includes `tokensOwed` only when it's known to be fees.
    let fees: Amounts
    let feesUSD: Decimal?
    let history: History
    let historyState: HistoryState
    /// Whether `fees` contains every unclaimed fee (else `tokensOwed` is shown as Claimable).
    let isFeesExact: Bool
    let lifetimeFees: Amounts?
    let liquidity: String
    /// Fees accrued since the position's last update, not yet credited to `tokensOwed`.
    let pendingFees: Amounts
    /// The block every value was read at.
    let pinned: BlockRef
    /// token1 per token0, decimals applied.
    let priceCurrent: Double
    let priceLower: Double
    let priceUpper: Double
    let tickCurrent: Int
    let tickLower: Int
    let tickUpper: Int
    let token0: Token
    let token1: Token
    let tokenId: String
    /// Principal from decreases plus credited fees, claimable with `collect`.
    let tokensOwed: Amounts
    /// Deployed plus claimable, in USD.
    let valueUSD: Decimal?

    var claimable: Amounts {
        tokensOwed + pendingFees
    }

    var status: Status {
        if BigUInt(liquidity) == 0 {
            return .withdrawn
        }

        return tickCurrent >= tickLower && tickCurrent < tickUpper ? .inRange : .outOfRange
    }

    // MARK: - Types

    /// Raw token amounts in base units, as decimal strings.
    struct Amounts: Codable, Equatable, Sendable {
        let token0: String
        let token1: String

        static let zero = Self(BigUInt(0), BigUInt(0))

        init(_ token0: BigUInt, _ token1: BigUInt) {
            self.token0 = String(token0)
            self.token1 = String(token1)
        }

        var amount0: BigUInt {
            BigUInt(token0) ?? 0
        }

        var amount1: BigUInt {
            BigUInt(token1) ?? 0
        }

        var isZero: Bool {
            amount0 == 0 && amount1 == 0
        }

        static func + (lhs: Self, rhs: Self) -> Self {
            Self(lhs.amount0 + rhs.amount0, lhs.amount1 + rhs.amount1)
        }

        static func += (lhs: inout Self, rhs: Self) {
            lhs = Self(lhs.amount0 + rhs.amount0, lhs.amount1 + rhs.amount1)
        }
    }

    /// History progress, persisted only through reorg-safe blocks and rechecked by hash.
    struct History: Codable, Equatable, Sendable {
        /// The newest block whose Collect and DecreaseLiquidity logs are in the sums.
        var checkpoint: BlockRef?
        var collected: Amounts = .zero
        var decreased: Amounts = .zero
        /// The mint block, once at or below the safe block.
        var mint: BlockRef?
        /// The newest block a mint search has covered without finding the mint.
        var mintSearchCursor: BlockRef?

        static let empty = Self()
    }

    enum HistoryState: String, Codable, Sendable {
        case complete
        case loading
        case unavailable
    }

    enum Status: String, Sendable {
        case inRange
        case outOfRange
        case withdrawn
    }

    struct Token: Codable, Equatable, Sendable {
        let address: String
        let decimals: Int
        let imageURL: URL?
        let priceAt: Date?
        let symbol: String
        let usdPrice: Decimal?

        func decimalAmount(_ amount: BigUInt) -> Decimal {
            Decimal(sign: .plus, exponent: -decimals, significand: Decimal(amount))
        }

        func usdValue(_ amount: BigUInt) -> Decimal? {
            usdPrice.map { decimalAmount(amount) * $0 }
        }
    }
}
