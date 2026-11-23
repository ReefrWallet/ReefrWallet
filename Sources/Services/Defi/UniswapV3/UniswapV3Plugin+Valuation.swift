//
//  UniswapV3Plugin+Valuation.swift
//  Reefr Wallet
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation

extension UniswapV3Plugin {
    static let minimumAPRAge: TimeInterval = 24 * 60 * 60
    static let secondsPerYear: Decimal = 365.25 * 24 * 60 * 60

    typealias TokenPair = (token0: UniswapV3Position.Token, token1: UniswapV3Position.Token)

    /// A position's fee figures; see ADR-073 for what each one means.
    struct Fees {
        /// The Fees column: pending fees, plus `tokensOwed` only when it can't hold principal.
        let fees: UniswapV3Position.Amounts
        let isExact: Bool
        let lifetime: UniswapV3Position.Amounts?
        let pending: UniswapV3Position.Amounts
    }

    /// Builds a position's record from its pinned state and history, or `.removed` when it's empty.
    static func outcome(
        key: String,
        chainId: UInt64,
        position: LivePosition,
        history: UniswapV3HistoryScanner.Result,
        tokens: TokenPair,
        pinned: BlockRef
    ) -> DefiPositionOutcome {
        let state = position.state
        let fees = fees(state, history: history)

        if state.liquidity == 0 && (state.tokensOwed + fees.pending).isZero {
            return .removed(key: key)
        }

        let valuation = Valuation(state: state, fees: fees, history: history, tokens: tokens, pinned: pinned)
        let payload = UniswapV3Position(
            apr: valuation.apr,
            chainId: chainId,
            createdAt: valuation.mint?.timestamp,
            deployed: valuation.deployed,
            deployedUSD: valuation.deployedUSD,
            fee: state.fee,
            fees: fees.fees,
            feesUSD: usd(fees.fees, tokens).complete,
            history: history.persisted,
            historyState: history.state,
            isFeesExact: fees.isExact,
            lifetimeFees: fees.lifetime,
            liquidity: String(state.liquidity),
            pendingFees: fees.pending,
            pinned: pinned,
            priceCurrent: price(sqrtPrice: state.pool.sqrtPrice, tokens),
            priceLower: price(tick: state.tickLower, tokens),
            priceUpper: price(tick: state.tickUpper, tokens),
            tickCurrent: state.pool.tick,
            tickLower: state.tickLower,
            tickUpper: state.tickUpper,
            token0: tokens.token0,
            token1: tokens.token1,
            tokenId: String(position.candidate.tokenId),
            tokensOwed: state.tokensOwed,
            valueUSD: valuation.value.complete
        )

        guard let data = try? payload.encoded() else {
            return .failed(key: key)
        }

        return .updated(
            DefiPositionRecord(
                key: key,
                payload: data,
                usdValue: valuation.value.priced ?? 0
            )
        )
    }

    /// Lifetime fees ÷ deployed value ÷ age in years; `nil` when any input is unknown or too young.
    static func annualRate(lifetimeFees: Decimal?, deployedUSD: Decimal?, age: TimeInterval?) -> Decimal? {
        guard let lifetimeFees, let deployedUSD, deployedUSD > 0, let age, age >= minimumAPRAge else {
            return nil
        }

        return lifetimeFees / deployedUSD / (Decimal(age) / secondsPerYear)
    }

    // MARK: - Private

    private static func fees(_ state: State, history: UniswapV3HistoryScanner.Result) -> Fees {
        let inside = UniswapV3Math.feeGrowthInside(
            tickCurrent: state.pool.tick,
            tickLower: state.tickLower,
            tickUpper: state.tickUpper,
            global: state.pool.feeGrowthGlobal,
            lowerOutside: state.tickOutsideLower,
            upperOutside: state.tickOutsideUpper
        )

        let last = state.feeGrowthInsideLast
        let pending = UniswapV3Position.Amounts(
            UniswapV3Math.pendingFees(liquidity: state.liquidity, inside: inside.token0, insideLast: last.token0),
            UniswapV3Math.pendingFees(liquidity: state.liquidity, inside: inside.token1, insideLast: last.token1)
        )

        let claimable = state.tokensOwed + pending
        let totals = history.state == .complete ? history.totals : nil
        // tokensOwed is pure fees only when no principal was ever withdrawn.
        let isExact = totals?.decreased.isZero == true
        let lifetime = totals.map { totals in
            UniswapV3Position.Amounts(
                clampedSub(totals.collected.amount0 + claimable.amount0, totals.decreased.amount0),
                clampedSub(totals.collected.amount1 + claimable.amount1, totals.decreased.amount1)
            )
        }

        return Fees(fees: isExact ? claimable : pending, isExact: isExact, lifetime: lifetime, pending: pending)
    }

    private static func clampedSub(_ lhs: BigUInt, _ rhs: BigUInt) -> BigUInt {
        lhs > rhs ? lhs - rhs : 0
    }

    private static func price(tick: Int, _ tokens: TokenPair) -> Double {
        UniswapV3Math.price(atTick: tick, decimals0: tokens.token0.decimals, decimals1: tokens.token1.decimals)
    }

    private static func price(sqrtPrice: BigUInt, _ tokens: TokenPair) -> Double {
        UniswapV3Math.price(sqrtPrice: sqrtPrice, decimals0: tokens.token0.decimals, decimals1: tokens.token1.decimals)
    }

    /// The USD value of `amounts`: `complete` only when every nonzero amount is priced; `priced` sums what is.
    private static func usd(_ amounts: UniswapV3Position.Amounts, _ tokens: TokenPair) -> USDValue {
        let parts = [(amounts.amount0, tokens.token0), (amounts.amount1, tokens.token1)].filter { $0.0 > 0 }
        let values = parts.map { $0.1.usdValue($0.0) }
        let priced = values.compactMap(\.self)
        let sum = priced.reduce(0, +)

        return USDValue(
            complete: values.contains(nil) ? nil : sum,
            priced: priced.isEmpty && !parts.isEmpty ? nil : sum
        )
    }

    private struct USDValue {
        let complete: Decimal?
        let priced: Decimal?
    }

    /// Deposits, total value and APR of a position at the pinned block.
    private struct Valuation {
        let apr: Decimal?
        let deployed: UniswapV3Position.Amounts
        let deployedUSD: Decimal?
        let mint: BlockRef?
        let value: USDValue

        init(state: State, fees: Fees, history: UniswapV3HistoryScanner.Result, tokens: TokenPair, pinned: BlockRef) {
            let amounts = UniswapV3Math.amounts(
                liquidity: state.liquidity,
                sqrtPrice: state.pool.sqrtPrice,
                tickLower: state.tickLower,
                tickUpper: state.tickUpper
            )

            deployed = UniswapV3Position.Amounts(amounts.amount0, amounts.amount1)
            deployedUSD = usd(deployed, tokens).complete
            value = usd(deployed + state.tokensOwed + fees.pending, tokens)
            mint = history.mint ?? history.persisted.mint
            apr = annualRate(
                lifetimeFees: fees.lifetime.flatMap { usd($0, tokens).complete },
                deployedUSD: deployedUSD,
                age: mint.map { pinned.timestamp.timeIntervalSince($0.timestamp) }
            )
        }
    }
}
