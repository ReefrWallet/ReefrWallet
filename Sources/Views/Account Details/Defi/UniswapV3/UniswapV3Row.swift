//
//  UniswapV3Row.swift
//  Reefr Wallet
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation

/// Display values of one stored Uniswap V3 position.
struct UniswapV3Row: Identifiable {
    /// Symbols treated as the quote side when orienting a pair's price.
    static let quoteSymbols: Set<String> = [
        "DAI", "FRAX", "LUSD", "PYUSD", "USDBC", "USDC", "USDC.E", "USDE", "USDS", "USDT", "USDT0", "USD₮0"
    ]

    let id: String
    let isUSDValueComplete: Bool
    let position: UniswapV3Position
    let usdValue: Decimal?

    init?(_ record: DefiPosition) {
        guard let position = try? record.payload.decoded() as UniswapV3Position else {
            return nil
        }

        id = record.id
        isUSDValueComplete = record.isUSDValueComplete
        self.position = position
        usdValue = record.usdValue
    }

    // MARK: - Pool

    /// "WETH / USDC", base first.
    var pairName: String {
        "\(base.symbol) / \(quote.symbol)"
    }

    /// "v3 · 0.05%".
    var feeTier: String {
        let percent = (Decimal(position.fee) / 1_000_000).formatted(.percent.precision(.fractionLength(0 ... 2)))
        return "v3 · \(percent)"
    }

    // MARK: - Range

    /// The token the price is quoted in: a stablecoin when one side is, else token1.
    var isInverted: Bool {
        Self.isQuote(position.token0) && !Self.isQuote(position.token1)
    }

    var base: UniswapV3Position.Token {
        isInverted ? position.token1 : position.token0
    }

    var quote: UniswapV3Position.Token {
        isInverted ? position.token0 : position.token1
    }

    /// "1,590.87 → 3,543.94 USDC".
    var rangeText: String {
        let (lower, upper) = isInverted
            ? (1 / position.priceUpper, 1 / position.priceLower)
            : (position.priceLower, position.priceUpper)

        return "\(Self.price(lower)) → \(Self.price(upper)) \(quote.symbol)"
    }

    // MARK: - Distribution

    /// Each token's share of the deployed value in USD, base first; `nil` if unpriced or empty.
    var distribution: (base: Double, quote: Double)? {
        let deployed = position.deployed
        let value0 = position.token0.usdValue(deployed.amount0)
        let value1 = position.token1.usdValue(deployed.amount1)

        guard let value0, let value1, value0 + value1 > 0 else {
            return nil
        }

        let share0 = NSDecimalNumber(decimal: value0 / (value0 + value1)).doubleValue
        return isInverted ? (1 - share0, share0) : (share0, 1 - share0)
    }

    // MARK: - Values

    /// "1,598.47 US$", "≥ …" when partly priced, "—" when unpriced.
    var valueText: String {
        Self.usd(usdValue, isComplete: isUSDValueComplete)
    }

    var feesText: String {
        if let feesUSD = position.feesUSD {
            return Self.usd(feesUSD, isComplete: true)
        }

        return Self.amounts(position.fees, position)
    }

    /// Owed amounts that may mix principal and fees, shown apart from Fees.
    var claimableText: String? {
        guard !position.isFeesExact, !position.tokensOwed.isZero else {
            return nil
        }

        let owed = position.tokensOwed
        let usd = [position.token0.usdValue(owed.amount0), position.token1.usdValue(owed.amount1)]

        if !usd.contains(nil) {
            return Self.usd(usd.compactMap(\.self).reduce(0, +), isComplete: true)
        }

        return Self.amounts(owed, position)
    }

    var lifetimeFeesText: String? {
        position.lifetimeFees.map { Self.amounts($0, position) }
    }

    var aprText: String? {
        position.apr.map { $0.formatted(.percent.precision(.fractionLength(2))) }
    }

    var createdText: String? {
        position.createdAt?.formatted(date: .numeric, time: .omitted)
    }

    var unpricedSymbols: String? {
        let symbols = [position.token0, position.token1].filter { $0.usdPrice == nil }.map(\.symbol)
        return symbols.isEmpty ? nil : symbols.formatted(.list(type: .and))
    }

    // MARK: - Sorting

    var sortValue: Decimal {
        usdValue ?? -1
    }

    var sortFees: Decimal {
        position.feesUSD ?? -1
    }

    var sortAPR: Decimal {
        position.apr ?? -1
    }

    var sortCreated: Date {
        position.createdAt ?? .distantPast
    }

    // MARK: - Private

    private static func isQuote(_ token: UniswapV3Position.Token) -> Bool {
        quoteSymbols.contains(token.symbol.uppercased())
    }

    private static func price(_ value: Double) -> String {
        guard value.isFinite else {
            return "∞"
        }

        return value >= 1
            ? value.formatted(.number.precision(.fractionLength(2)))
            : value.formatted(.number.precision(.significantDigits(4)))
    }

    private static func usd(_ value: Decimal?, isComplete: Bool) -> String {
        guard let value else {
            return "—"
        }

        let text = "\(value.formattedAbbreviated()) US$"
        return isComplete ? text : "≥ \(text)"
    }

    private static func amounts(_ amounts: UniswapV3Position.Amounts, _ position: UniswapV3Position) -> String {
        [(amounts.amount0, position.token0), (amounts.amount1, position.token1)]
            .filter { $0.0 > 0 }
            .map { $0.1.decimalAmount($0.0).formatted(symbol: $0.1.symbol) }
            .joined(separator: " + ")
            .nonEmpty ?? "0"
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
