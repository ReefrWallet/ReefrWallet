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
    let position: UniswapV3Position
    let usdValue: Decimal

    init?(_ record: DefiPosition) {
        guard let position = try? record.payload.decoded() as UniswapV3Position else {
            return nil
        }

        id = record.id
        self.position = position
        usdValue = record.usdValue
    }

    // MARK: - Pool

    /// "WETH / USDC", base first.
    var pairName: String {
        "\(base.symbol) / \(quote.symbol)"
    }

    /// "0.05%".
    var feeTier: String {
        (Decimal(position.fee) / 1_000_000).formatted(.percent.precision(.fractionLength(0 ... 2)))
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

    /// Whether the range spans every price the pool allows.
    var isFullRange: Bool {
        isMinTick && isMaxTick
    }

    /// "1,590.87 → 3,543.94 USDC"; "0" and "∞" for the pool's price limits.
    var rangeText: String {
        let lower = isInverted
            ? (isMaxTick ? "0" : Self.price(1 / position.priceUpper))
            : (isMinTick ? "0" : Self.price(position.priceLower))
        let upper = isInverted
            ? (isMinTick ? "∞" : Self.price(1 / position.priceLower))
            : (isMaxTick ? "∞" : Self.price(position.priceUpper))

        return "\(lower) → \(upper) \(quote.symbol)"
    }

    /// Ticks are multiples of the pool's spacing, so the usable limits sit within one spacing of ±887,272.
    private var isMaxTick: Bool {
        UniswapV3Math.maxTick - position.tickUpper < Self.tickSpacing(fee: position.fee)
    }

    private var isMinTick: Bool {
        position.tickLower - UniswapV3Math.minTick < Self.tickSpacing(fee: position.fee)
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

    /// "0.5 WETH + 790 USDC": the tokens providing liquidity, base first.
    var pooledText: String {
        let deployed = position.deployed
        let pooled = [(deployed.amount0, position.token0), (deployed.amount1, position.token1)]
        return Self.amounts(isInverted ? pooled.reversed() : pooled)
    }

    // MARK: - Values

    /// "1,598.47 US$": the priced parts.
    var valueText: String {
        Self.usd(usdValue)
    }

    var feesText: String {
        if let feesUSD = position.feesUSD {
            return Self.usd(feesUSD)
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
            return Self.usd(usd.compactMap(\.self).reduce(0, +))
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

    private static func usd(_ value: Decimal) -> String {
        "\(value.formattedAbbreviated()) US$"
    }

    private static func amounts(_ amounts: UniswapV3Position.Amounts, _ position: UniswapV3Position) -> String {
        Self.amounts([(amounts.amount0, position.token0), (amounts.amount1, position.token1)])
    }

    /// Non-zero amounts joined with "+"; ones too small to show read "<0.000001".
    private static func amounts(_ amounts: [(BigUInt, UniswapV3Position.Token)]) -> String {
        amounts
            .filter { $0.0 > 0 }
            .map { amount, token in
                let value = token.decimalAmount(amount)
                return value < smallestAmount
                    ? "<\(smallestAmount.formatted(symbol: token.symbol))"
                    : value.formatted(symbol: token.symbol)
            }
            .joined(separator: " + ")
            .nonEmpty ?? "0"
    }

    private static let smallestAmount = Decimal(sign: .plus, exponent: -6, significand: 1)

    /// The pool's tick spacing by fee tier; the widest when the tier is unknown.
    private static func tickSpacing(fee: UInt32) -> Int {
        [100: 1, 500: 10, 2_500: 50, 3_000: 60, 10_000: 200][fee] ?? 200
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
