// Uniswap V3 TickMath, LiquidityAmounts and fee-growth ports against the
// contracts' known values (ADR-073).

import BigInt
import Foundation
import Testing
import WalletKit
@testable import ReefrWallet

struct UniswapV3MathTests {
    @Test func sqrtRatioMatchesTickMathBounds() {
        #expect(UniswapV3Math.sqrtRatio(atTick: 0) == BigUInt(1) << 96)
        #expect(UniswapV3Math.sqrtRatio(atTick: UniswapV3Math.minTick) == 4_295_128_739)
        #expect(
            UniswapV3Math.sqrtRatio(atTick: UniswapV3Math.maxTick)
                == BigUInt("1461446703485210103287273052203988822378723970342")
        )
    }

    @Test func sqrtRatioTracksOnePointZeroZeroZeroOnePerTick() {
        for tick in [-200_000, -60, -1, 1, 60, 200_000] {
            let expected = pow(1.0001, Double(tick) / 2) * pow(2, 96)
            let actual = Double(UniswapV3Math.sqrtRatio(atTick: tick))

            #expect(abs(actual / expected - 1) < 1e-9, "tick \(tick)")
        }
    }

    @Test func amountsBelowInsideAndAboveTheRange() {
        let liquidity = BigUInt(10).power(18)
        let below = UniswapV3Math.amounts(
            liquidity: liquidity, sqrtPrice: UniswapV3Math.sqrtRatio(atTick: -1_000), tickLower: -600, tickUpper: 600
        )

        let inside = UniswapV3Math.amounts(
            liquidity: liquidity, sqrtPrice: UniswapV3Math.sqrtRatio(atTick: 0), tickLower: -600, tickUpper: 600
        )

        let above = UniswapV3Math.amounts(
            liquidity: liquidity, sqrtPrice: UniswapV3Math.sqrtRatio(atTick: 1_000), tickLower: -600, tickUpper: 600
        )

        #expect(below.amount0 > 0 && below.amount1 == 0)
        #expect(above.amount0 == 0 && above.amount1 > 0)
        // Symmetric range at price 1: equal halves, each L·(1 − 1.0001^−300).
        let half = Double(liquidity) * (1 - pow(1.0001, -300))
        #expect(abs(Double(inside.amount0) / half - 1) < 1e-6)
        #expect(abs(Double(inside.amount1) / half - 1) < 1e-6)
        #expect(below.amount0 > inside.amount0)
    }

    @Test func feeGrowthInsideWrapsLikeTheContract() {
        let global = UniswapV3Math.FeeGrowth(token0: 10, token1: 10)
        // Outside values larger than the global value happen after tick crossings.
        let lower = UniswapV3Math.FeeGrowth(token0: 15, token1: 0)
        let upper = UniswapV3Math.FeeGrowth(token0: 0, token1: 0)

        let inside = UniswapV3Math.feeGrowthInside(
            tickCurrent: 0, tickLower: -60, tickUpper: 60, global: global, lowerOutside: lower, upperOutside: upper
        )

        #expect(inside.token0 == UniswapV3Math.two256 - 5)
        #expect(inside.token1 == 10)

        // Last snapshot taken before the wrap: the difference is still the accrued growth.
        let pending = UniswapV3Math.pendingFees(
            liquidity: BigUInt(1) << 128, inside: inside.token0, insideLast: UniswapV3Math.two256 - 8
        )
        #expect(pending == 3)
    }

    @Test func feeGrowthOutsideTheRangeUsesTheOtherSide() {
        let global = UniswapV3Math.FeeGrowth(token0: 100, token1: 100)
        let lower = UniswapV3Math.FeeGrowth(token0: 30, token1: 30)
        let upper = UniswapV3Math.FeeGrowth(token0: 20, token1: 20)

        let below = UniswapV3Math.feeGrowthInside(
            tickCurrent: -100, tickLower: -60, tickUpper: 60, global: global, lowerOutside: lower, upperOutside: upper
        )

        let above = UniswapV3Math.feeGrowthInside(
            tickCurrent: 100, tickLower: -60, tickUpper: 60, global: global, lowerOutside: lower, upperOutside: upper
        )

        // Below: lower.outside − upper.outside; above: upper.outside − lower.outside (mod 2^256).
        #expect(below.token0 == 10)
        #expect(above.token0 == UniswapV3Math.two256 - 10)
    }

    @Test func annualRateNeedsADayAndADenominator() {
        let year = 365.25 * 24 * 60 * 60

        #expect(UniswapV3Plugin.annualRate(lifetimeFees: 10, deployedUSD: 100, age: year) == Decimal(string: "0.1"))
        #expect(UniswapV3Plugin.annualRate(lifetimeFees: 10, deployedUSD: 0, age: year) == nil)
        #expect(UniswapV3Plugin.annualRate(lifetimeFees: 10, deployedUSD: 100, age: 3_600) == nil)
        #expect(UniswapV3Plugin.annualRate(lifetimeFees: nil, deployedUSD: 100, age: year) == nil)
    }

    @Test func multicallRoundTrip() throws {
        let target = try EthereumAddress(string: "0x" + String(repeating: "12", count: 20))
        let encoded = Multicall3.encodeAggregate3([EVMCall(data: Data([1, 2, 3]), target: target)])
        #expect(encoded.prefix(4) == Multicall3.aggregate3)

        // ((true, 0x0a0b), (false, Error("x")))
        let revert = FakeUniswapV3Chain.errorRevert("x")
        let returned = FakeUniswapV3Chain.words([32, 2, 64, 192, 1, 64, 2])
            + Data([10, 11]) + Data(repeating: 0, count: 30)
            + FakeUniswapV3Chain.words([0, 64, BigUInt(revert.count)])
            + revert + Data(repeating: 0, count: (32 - revert.count % 32) % 32)
        let results = try Multicall3.decodeAggregate3(returned)

        #expect(results == [
            EVMCallResult(data: Data([10, 11]), isSuccess: true),
            EVMCallResult(data: revert, isSuccess: false)
        ])
        #expect(results[1].revertReason == "x")
    }

    @Test func indexedLogQueriesSplitOrTopicsAndParseBothExplorers() throws {
        #expect(EtherscanCompatibleLogs.combinations([["a", "b"], ["t"]]) == [["a", "t"], ["b", "t"]])
        #expect(EtherscanCompatibleLogs.combinations([["a"], nil, ["t"]]) == [["a", nil, "t"]])

        // Blockscout: no block hash, hex numbers; Etherscan: "No records found".
        let blockscout = Data("""
        {"message":"OK","result":[{"blockNumber":"0x1a","data":"0x01","logIndex":"0x2",\
        "topics":["0xAA",null],"transactionHash":"0xBB"}],"status":"1"}
        """.utf8)
        let logs = try JSONDecoder().decode(CompatibleLogsResponse.self, from: blockscout).logs()
        #expect(logs == [EVMLog(
            blockHash: "",
            blockNumber: 26,
            data: Data([1]),
            logIndex: 2,
            topics: ["0xaa"],
            transactionHash: "0xbb"
        )])

        let empty = Data(#"{"message":"No records found","result":[],"status":"0"}"#.utf8)
        #expect(try JSONDecoder().decode(CompatibleLogsResponse.self, from: empty).logs().isEmpty)

        let none = Data(#"{"message":"No logs found","result":null,"status":"0"}"#.utf8)
        #expect(try JSONDecoder().decode(CompatibleLogsResponse.self, from: none).logs().isEmpty)
    }
}
