//
//  UniswapV3Math.swift
//  Reefr Wallet
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation

/// Exact ports of Uniswap V3's `TickMath`, `LiquidityAmounts` and position fee math.
enum UniswapV3Math {
    static let maxTick = 887_272
    static let minTick = -887_272
    static let q96 = BigUInt(1) << 96
    static let q128 = BigUInt(1) << 128
    static let two256 = BigUInt(1) << 256

    // MARK: - Ticks

    /// `TickMath.getSqrtRatioAtTick`: sqrt(1.0001^tick) as Q64.96.
    static func sqrtRatio(atTick tick: Int) -> BigUInt {
        precondition(tick >= minTick && tick <= maxTick, "tick out of range")

        let absTick = UInt(abs(tick))
        var ratio = absTick & 0x1 != 0 ? oddTickRatio : BigUInt(1) << 128

        for (bit, multiplier) in tickMultipliers where absTick & bit != 0 {
            ratio = (ratio * multiplier) >> 128
        }

        if tick > 0 {
            ratio = (two256 - 1) / ratio
        }

        // Q128.128 → Q128.96, rounding up.
        return (ratio >> 32) + (ratio % (BigUInt(1) << 32) == 0 ? 0 : 1)
    }

    // MARK: - Amounts

    /// `LiquidityAmounts.getAmountsForLiquidity`, rounding down like the pool's view.
    static func amounts(
        liquidity: BigUInt,
        sqrtPrice: BigUInt,
        tickLower: Int,
        tickUpper: Int
    ) -> (amount0: BigUInt, amount1: BigUInt) {
        let sqrtA = sqrtRatio(atTick: tickLower)
        let sqrtB = sqrtRatio(atTick: tickUpper)

        if sqrtPrice <= sqrtA {
            return (amount0(liquidity: liquidity, sqrtA: sqrtA, sqrtB: sqrtB), 0)
        }

        if sqrtPrice < sqrtB {
            return (
                amount0(liquidity: liquidity, sqrtA: sqrtPrice, sqrtB: sqrtB),
                amount1(liquidity: liquidity, sqrtA: sqrtA, sqrtB: sqrtPrice)
            )
        }

        return (0, amount1(liquidity: liquidity, sqrtA: sqrtA, sqrtB: sqrtB))
    }

    static func amount0(liquidity: BigUInt, sqrtA: BigUInt, sqrtB: BigUInt) -> BigUInt {
        let (lower, upper) = sqrtA < sqrtB ? (sqrtA, sqrtB) : (sqrtB, sqrtA)

        guard lower > 0 else {
            return 0
        }

        return ((liquidity << 96) * (upper - lower) / upper) / lower
    }

    static func amount1(liquidity: BigUInt, sqrtA: BigUInt, sqrtB: BigUInt) -> BigUInt {
        let (lower, upper) = sqrtA < sqrtB ? (sqrtA, sqrtB) : (sqrtB, sqrtA)
        return liquidity * (upper - lower) / q96
    }

    // MARK: - Fees

    /// A tick's `feeGrowthOutside` for both tokens.
    struct FeeGrowth: Equatable, Sendable {
        let token0: BigUInt
        let token1: BigUInt
    }

    /// `Tick.getFeeGrowthInside`, wrapping modulo 2^256 like the contract.
    static func feeGrowthInside(
        tickCurrent: Int,
        tickLower: Int,
        tickUpper: Int,
        global: FeeGrowth,
        lowerOutside: FeeGrowth,
        upperOutside: FeeGrowth
    ) -> FeeGrowth {
        func inside(_ global: BigUInt, _ lower: BigUInt, _ upper: BigUInt) -> BigUInt {
            let below = tickCurrent >= tickLower ? lower : sub(global, lower)
            let above = tickCurrent < tickUpper ? upper : sub(global, upper)
            return sub(sub(global, below), above)
        }

        return FeeGrowth(
            token0: inside(global.token0, lowerOutside.token0, upperOutside.token0),
            token1: inside(global.token1, lowerOutside.token1, upperOutside.token1)
        )
    }

    /// Fees accrued since the position's last update: `(inside − last) · L / 2^128`.
    static func pendingFees(liquidity: BigUInt, inside: BigUInt, insideLast: BigUInt) -> BigUInt {
        // The contract truncates the product to uint128 tokensOwed; positions never get near that.
        (sub(inside, insideLast) * liquidity) / q128
    }

    /// Subtraction modulo 2^256.
    static func sub(_ lhs: BigUInt, _ rhs: BigUInt) -> BigUInt {
        lhs >= rhs ? lhs - rhs : two256 - (rhs - lhs)
    }

    // MARK: - Prices

    /// token1 per token0 at `tick`, adjusted for decimals; for display only.
    static func price(atTick tick: Int, decimals0: Int, decimals1: Int) -> Double {
        pow(1.0001, Double(tick)) * pow(10, Double(decimals0 - decimals1))
    }

    /// token1 per token0 from a Q64.96 square-root price; for display only.
    static func price(sqrtPrice: BigUInt, decimals0: Int, decimals1: Int) -> Double {
        let ratio = Double(sqrtPrice) / Double(q96)
        return ratio * ratio * pow(10, Double(decimals0 - decimals1))
    }

    // MARK: - Private

    // swiftlint:disable force_unwrapping
    private static let oddTickRatio = BigUInt("fffcb933bd6fad37aa2d162d1a594001", radix: 16)!

    private static let tickMultipliers: [(UInt, BigUInt)] = [
        (0x2, "fff97272373d413259a46990580e213a"),
        (0x4, "fff2e50f5f656932ef12357cf3c7fdcc"),
        (0x8, "ffe5caca7e10e4e61c3624eaa0941cd0"),
        (0x10, "ffcb9843d60f6159c9db58835c926644"),
        (0x20, "ff973b41fa98c081472e6896dfb254c0"),
        (0x40, "ff2ea16466c96a3843ec78b326b52861"),
        (0x80, "fe5dee046a99a2a811c461f1969c3053"),
        (0x100, "fcbe86c7900a88aedcffc83b479aa3a4"),
        (0x200, "f987a7253ac413176f2b074cf7815e54"),
        (0x400, "f3392b0822b70005940c7a398e4b70f3"),
        (0x800, "e7159475a2c29b7443b29c7fa6e889d9"),
        (0x1000, "d097f3bdfd2022b8845ad8f792aa5825"),
        (0x2000, "a9f746462d870fdf8a65dc1f90e061e5"),
        (0x4000, "70d869a156d2a1b890bb3df62baf32f7"),
        (0x8000, "31be135f97d08fd981231505542fcfa6"),
        (0x10000, "9aa508b5b7a84e1c677de54f3e99bc9"),
        (0x20000, "5d6af8dedb81196699c329225ee604"),
        (0x40000, "2216e584f5fa1ea926041bedfe98"),
        (0x80000, "48a170391f7dc42444e8fa2")
    ].map { ($0.0, BigUInt($0.1, radix: 16)!) }
    // swiftlint:enable force_unwrapping
}
