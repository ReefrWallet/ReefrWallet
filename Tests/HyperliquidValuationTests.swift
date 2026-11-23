// Hyperliquid Portfolio Value and Unrealized PnL from recorded live accounts
// (TestVectors/Hyperliquid) and synthetic edge cases (ADR-074).

import Foundation
import Testing
@testable import ReefrWallet

struct HyperliquidValuationTests {
    /// Recorded accounts whose value must match Hyperliquid's own account value.
    @Test(arguments: [
        "hyperliquid-pm-debt",
        "hyperliquid-pm-isolated",
        "hyperliquid-standard-cross",
        "hyperliquid-standard-isolated",
        "hyperliquid-standard-vault",
        "hyperliquid-unified-hip3",
        "hyperliquid-unified-isolated",
        "hyperliquid-unified-lending"
    ])
    func matchesHyperliquidsAccountValue(_ name: String) async throws {
        let fixture = try HyperliquidFixture(name)
        let input = try await fixture.input()
        let position = try #require(HyperliquidValuation.value(input))
        let value = try #require(position.portfolioValue.usd)
        let reference = try #require(fixture.referenceAccountValue)

        #expect(position.portfolioValue.state == .complete)
        // Prices and the reference were read seconds apart.
        #expect(abs(value - reference) / reference < 0.005, "\(name): \(value) vs \(reference)")
    }

    @Test func outcomeHoldingsWithoutATokenMakeALowerBound() async throws {
        let fixture = try HyperliquidFixture("hyperliquid-standard-outcomes")
        let input = try await fixture.input()
        let position = try #require(HyperliquidValuation.value(input))
        let value = try #require(position.portfolioValue.usd)

        #expect(position.portfolioValue.state == .lowerBound)
        #expect(position.unpricedCoins.allSatisfy { $0.hasPrefix("+") })
        #expect(!position.unpricedCoins.isEmpty)
        #expect(try value <= #require(fixture.referenceAccountValue))
        #expect(position.unrealizedPnl.state == .complete)
    }

    @Test func unifiedAccountsDontAddPerpEquityToSpot() async throws {
        let input = try await HyperliquidFixture("hyperliquid-unified-isolated").input()
        let position = try #require(HyperliquidValuation.value(input))

        let perps = try #require(position.breakdown.perps)
        let value = try #require(position.portfolioValue.usd)

        #expect(perps > 0)
        #expect(value == position.breakdown.spot + position.breakdown.vaults + (position.breakdown.staked ?? 0))
        #expect(position.openPositionCount > 0)
    }

    @Test func testnetIsPricedFromTestnetMetadataAndStaysOutOfTotals() async throws {
        let fixture = try HyperliquidFixture(
            "hyperliquid-testnet-stake",
            metadata: "hyperliquid-testnet-metadata"
        )

        let input = try await fixture.input(network: .testnet)
        let position = try #require(HyperliquidValuation.value(input))
        let record = try position.record

        #expect(try #require(position.breakdown.staked) > 0)
        #expect(position.network == .testnet)
        #expect(record.usdValue == 0)
    }

    // MARK: - Synthetic

    /// No live standard-mode account had non-USDC collateral to reconcile (ADR-074).
    @Test func nonUSDCCollateralIsConvertedButNotYetTrusted() async throws {
        var input = try await HyperliquidFixture("hyperliquid-standard-vault").input()
        let usdh = try #require(input.spotMeta.meta.tokens.first { $0.name == "USDH" }?.index)
        let price = try #require(HyperliquidValuation.prices(input.spotMeta)[usdh])
        let dex = try #require(input.perpMetas.first { $0.collateralToken == usdh }?.dex)

        input = input.replacing(clearinghouse: Self.clearinghouse(equity: "100", pnl: "-10"), dex: dex)
        let position = try #require(HyperliquidValuation.value(input))

        #expect(position.breakdown.perps == 100 * price)
        #expect(position.unrealizedPnl == HyperliquidPosition.Metric(state: .partial, usd: -10 * price))
        #expect(position.portfolioValue.state == .unavailable)
    }

    @Test func unpricedCollateralMakesBothMetricsPartial() async throws {
        var input = try await HyperliquidFixture("hyperliquid-standard-vault").input()
        let dex = try #require(input.perpMetas.first { $0.dex != "" }?.dex)

        input = input.replacing(clearinghouse: Self.clearinghouse(equity: "100", pnl: "-10"), dex: dex)
        input = input.replacing(perpMetas: input.perpMetas.map { meta in
            meta.dex == dex ? Hyperliquid.PerpMeta(collateralToken: 999_999, universe: meta.universe) : meta
        })

        let position = try #require(HyperliquidValuation.value(input))
        #expect(position.portfolioValue.state == .unavailable)
        #expect(position.unrealizedPnl.state == .partial)
        #expect(position.breakdown.perps == nil)
        #expect(try position.record.usdValue == 0)
    }

    @Test func aNegativeUnpricedBalanceMakesPortfolioValuePartial() async throws {
        var input = try await HyperliquidFixture("hyperliquid-pm-debt").input()
        let json = #"{"balances":[{"coin":"+1","total":"-5.0","hold":"0.0","entryNtl":"0.0"}]}"#
        input = input.replacing(spot: try json.decoded())

        let position = try #require(HyperliquidValuation.value(input))
        #expect(position.portfolioValue.state == .partial)
        #expect(try position.record.usdValue == position.portfolioValue.usd ?? 0)
    }

    @Test func unpricedStakeOnlyMakesALowerBound() async throws {
        var input = try await HyperliquidFixture("hyperliquid-standard-cross").input()
        input = input.replacing(spotMeta: input.spotMeta.removingPair(for: "HYPE"))

        let position = try #require(HyperliquidValuation.value(input))
        #expect(position.portfolioValue.state == .lowerBound)
        #expect(position.unrealizedPnl.state == .complete)
        #expect(try position.record.usdValue == position.portfolioValue.usd)
    }

    @Test(arguments: ["dexAbstraction", "somethingNew"])
    func anUnreconciledModeIsUnavailable(_ mode: String) async throws {
        let input = try await HyperliquidFixture("hyperliquid-standard-cross").input().replacing(mode: mode)
        let position = try #require(HyperliquidValuation.value(input))

        #expect(position.portfolioValue.state == .unavailable)
        #expect(position.unrealizedPnl.state == .complete)
        #expect(try position.record.usdValue == 0)
    }

    @Test func skippedDexesMakeBothMetricsPartialInStandardMode() async throws {
        let input = try await HyperliquidFixture("hyperliquid-standard-cross").input().replacing(unqueriedDexCount: 3)
        let position = try #require(HyperliquidValuation.value(input))

        #expect(position.portfolioValue.state == .partial)
        #expect(position.unrealizedPnl.state == .partial)
    }

    @Test func anEmptyAccountHasNoPosition() async throws {
        let input = try await HyperliquidFixture("hyperliquid-standard-vault").input().emptied()
        #expect(HyperliquidValuation.value(input) == nil)
    }

    @Test func aNonzeroUnpricedStakeKeepsTheRow() async throws {
        var input = try await HyperliquidFixture("hyperliquid-standard-vault").input().emptied()
        input = input.replacing(stake: Self.stake("5"))
        input = input.replacing(spotMeta: input.spotMeta.removingPair(for: "HYPE"))

        let position = try #require(HyperliquidValuation.value(input))
        #expect(position.portfolioValue.state == .lowerBound)
    }

    @Test func aTokenlessSpotEntryDecodes() throws {
        let json = #"{"balances":[{"coin":"+1230","total":"5.0","hold":"0.0","entryNtl":"0.0"}]}"#
        let state: Hyperliquid.SpotClearinghouseState = try json.decoded()

        #expect(state.balances.first?.token == nil)
        #expect(state.balances.first?.total.value == 5)
    }

    // MARK: - Helpers

    static func clearinghouse(equity: String, pnl: String) -> Hyperliquid.ClearinghouseState {
        let json = """
        {"marginSummary":{"accountValue":"\(equity)"},"assetPositions":[{"position":{"coin":"x:X","leverage":{"type":"cross"},\
        "marginUsed":"1","szi":"1","unrealizedPnl":"\(pnl)"}}]}
        """
        // swiftlint:disable:next force_try
        return try! json.decoded()
    }

    static func stake(_ delegated: String) -> Hyperliquid.DelegatorSummary {
        // swiftlint:disable:next force_try
        try! #"{"delegated":"\#(delegated)","undelegated":"0","totalPendingWithdrawal":"0"}"#.decoded()
    }
}

private extension HyperliquidValuation.Input {
    /// No balances, positions, lending, vaults or stake.
    func emptied() -> Self {
        Self(
            borrowLend: Hyperliquid.BorrowLendUserState(tokens: [:]),
            clearinghouses: [:],
            mode: mode,
            network: network,
            perpMetas: perpMetas,
            spot: Hyperliquid.SpotClearinghouseState(balances: []),
            spotMeta: spotMeta,
            stake: HyperliquidValuationTests.stake("0"),
            unqueriedDexCount: 0,
            vaults: []
        )
    }

    func replacing(
        clearinghouse: Hyperliquid.ClearinghouseState? = nil,
        dex: String = "",
        mode: String? = nil,
        perpMetas: [Hyperliquid.PerpMeta]? = nil,
        spot: Hyperliquid.SpotClearinghouseState? = nil,
        spotMeta: Hyperliquid.SpotMetaAndAssetCtxs? = nil,
        stake: Hyperliquid.DelegatorSummary? = nil,
        unqueriedDexCount: Int? = nil
    ) -> Self {
        var clearinghouses = clearinghouses

        if let clearinghouse {
            clearinghouses[dex] = clearinghouse
        }

        return Self(
            borrowLend: borrowLend,
            clearinghouses: clearinghouses,
            mode: mode ?? self.mode,
            network: network,
            perpMetas: perpMetas ?? self.perpMetas,
            spot: spot ?? self.spot,
            spotMeta: spotMeta ?? self.spotMeta,
            stake: stake ?? self.stake,
            unqueriedDexCount: unqueriedDexCount ?? self.unqueriedDexCount,
            vaults: vaults
        )
    }
}

private extension Hyperliquid.SpotMetaAndAssetCtxs {
    /// The same metadata without `symbol`'s USDC pair, so it has no price.
    func removingPair(for symbol: String) -> Self {
        let token = meta.tokens.first { $0.name == symbol }?.index
        return Self(
            contexts: contexts,
            meta: Meta(tokens: meta.tokens, universe: meta.universe.filter { $0.tokens.first != token })
        )
    }
}
