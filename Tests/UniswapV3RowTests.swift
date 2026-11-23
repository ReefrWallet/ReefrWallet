// Uniswap V3 row display values (ADR-073).

import Foundation
import Testing
@testable import ReefrWallet

struct UniswapV3RowTests {
    /// Usable tick limits for the 0.05% tier (spacing 10).
    static let maxTick = 887_270
    static let minTick = -887_270

    @Test func feeTierIsJustThePercent() throws {
        let row = try #require(UniswapV3Row(.uniswapPreview(id: "1")))

        #expect(!row.feeTier.contains("v3"))
        #expect(row.feeTier.contains("05"))
    }

    @Test func fullRangeSpansBothLimits() throws {
        let row = try #require(UniswapV3Row(.uniswapPreview(id: "1", ticks: (Self.minTick, Self.maxTick))))

        #expect(row.isFullRange)
    }

    @Test func limitsReadAsZeroAndInfinity() throws {
        let lower = try #require(UniswapV3Row(.uniswapPreview(id: "1", ticks: (Self.minTick, -191_100))))
        let upper = try #require(UniswapV3Row(.uniswapPreview(id: "2", ticks: (-199_200, Self.maxTick))))

        #expect(!lower.isFullRange)
        #expect(lower.rangeText.hasPrefix("0 → "))
        #expect(!lower.rangeText.contains("∞"))
        #expect(upper.rangeText.hasSuffix("→ ∞ USDC"))
    }

    @Test func ticksOneSpacingInsideTheLimitsArePrices() throws {
        let row = try #require(UniswapV3Row(.uniswapPreview(id: "1", ticks: (Self.minTick + 10, Self.maxTick - 10))))

        #expect(!row.isFullRange)
        #expect(!row.rangeText.hasPrefix("0 → "))
        #expect(!row.rangeText.contains("∞"))
    }

    @Test func pooledAmountsListBaseThenQuote() throws {
        let row = try #require(UniswapV3Row(.uniswapPreview(id: "1")))
        let weth = try #require(Decimal(string: "0.5"))
        let expected = "\(weth.formatted(symbol: "WETH")) + \(Decimal(39).formatted(symbol: "USDC"))"

        #expect(row.pooledText == expected)
    }
}
