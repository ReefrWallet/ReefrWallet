//
//  HyperliquidValuation.swift
//  Reefr Wallet
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation

/// Turns one account's `/info` responses into Portfolio Value and Unrealized
/// PnL. Formulas per account mode were reconciled against Hyperliquid's own
/// account value on live accounts (ADR-074).
enum HyperliquidValuation {
    /// How an account mode's balances add up.
    enum Formula: Equatable {
        /// Spot already holds perp equity and lending, net of debt.
        case portfolioMargin
        /// Separate spot and per-dex perp balances.
        case standard
        /// Spot holds perp equity; lending is separate.
        case unified
        /// No reconciled formula.
        case unknown

        init(mode: String) {
            switch mode {
            case "default", "disabled": self = .standard
            case "portfolioMargin": self = .portfolioMargin
            case "unifiedAccount": self = .unified
            default: self = .unknown
            }
        }
    }

    struct Input: Sendable {
        let borrowLend: Hyperliquid.BorrowLendUserState
        /// By dex name; `""` is the first dex.
        let clearinghouses: [String: Hyperliquid.ClearinghouseState]
        let mode: String
        let network: HyperliquidNetwork
        let perpMetas: [Hyperliquid.PerpMeta]
        let spot: Hyperliquid.SpotClearinghouseState
        let spotMeta: Hyperliquid.SpotMetaAndAssetCtxs
        let stake: Hyperliquid.DelegatorSummary
        /// Dexes not queried this run (over the per-run cap).
        let unqueriedDexCount: Int
        let vaults: [Hyperliquid.VaultEquity]
    }

    /// USD prices by spot token index: the mark of the token's USDC pair; USDC is 1.
    static func prices(_ spotMeta: Hyperliquid.SpotMetaAndAssetCtxs) -> [Int: Decimal] {
        let marks = Dictionary(
            spotMeta.contexts.compactMap { context in context.markPx.map { (context.coin, $0.value) } }
        ) { first, _ in first }

        var prices: [Int: Decimal] = [0: 1]

        for pair in spotMeta.meta.universe where pair.tokens.count == 2 && pair.tokens[1] == 0 {
            if let mark = marks[pair.name], mark > 0 {
                prices[pair.tokens[0]] = mark
            }
        }

        return prices
    }

    /// `nil` when the account holds nothing on HyperCore.
    static func value(_ input: Input) -> HyperliquidPosition? {
        let prices = prices(input.spotMeta)
        let spot = spotParts(input, prices: prices)
        let perps = perpParts(input, prices: prices)
        let lending = lendingParts(input, prices: prices)
        let vaultsUSD = input.vaults.reduce(Decimal.zero) { $0 + $1.equity.value }
        let stakedHYPE = input.stake.total
        let hype = input.spotMeta.meta.tokens.first { $0.name == "HYPE" }?.index
        let stakedUSD: Decimal? = stakedHYPE == 0 ? 0 : hype.flatMap { prices[$0] }.map { stakedHYPE * $0 }

        let isEmpty = perps.positionCount == 0 && spot.unpricedCoins.isEmpty && spot.usd == 0 && perps.equityUSD == 0
            && !lending.isActive && vaultsUSD == 0 && stakedHYPE == 0

        guard !isEmpty else {
            return nil
        }

        let parts = Parts(
            hasNonUSDCCollateral: perps.hasNonUSDCCollateral,
            lending: lending,
            perpsUSD: input.unqueriedDexCount > 0 ? nil : perps.equityUSD,
            spot: spot,
            stakedUSD: stakedUSD,
            vaultsUSD: vaultsUSD
        )

        return HyperliquidPosition(
            breakdown: HyperliquidPosition.Breakdown(
                borrowed: lending.borrowedUSD,
                lent: lending.lentUSD,
                perps: perps.equityUSD,
                spot: spot.usd,
                staked: stakedUSD,
                vaults: vaultsUSD
            ),
            mode: input.mode,
            network: input.network,
            openPositionCount: perps.positionCount,
            portfolioValue: portfolioValue(Formula(mode: input.mode), parts: parts),
            unpricedCoins: spot.unpricedCoins,
            unrealizedPnl: HyperliquidPosition.Metric(
                state: perps.isPnlPartial || perps.hasNonUSDCCollateral || input.unqueriedDexCount > 0
                    ? .partial
                    : .complete,
                usd: perps.pnlUSD
            )
        )
    }
}

// MARK: - Parts

private extension HyperliquidValuation {
    struct LendingParts {
        /// `nil` when a borrowed token is unpriced.
        var borrowedUSD: Decimal? = 0
        var isActive = false
        /// `nil` when a lent token is unpriced.
        var lentUSD: Decimal? = 0
    }

    struct Parts {
        let hasNonUSDCCollateral: Bool
        let lending: LendingParts
        let perpsUSD: Decimal?
        let spot: SpotParts
        let stakedUSD: Decimal?
        let vaultsUSD: Decimal
    }

    struct PerpParts {
        /// `nil` when a dex's collateral is unpriced.
        var equityUSD: Decimal? = 0
        /// Equity or PnL on a dex whose collateral isn't USDC: converted, but not reconciled live yet.
        var hasNonUSDCCollateral = false
        var isPnlPartial = false
        var pnlUSD: Decimal = 0
        var positionCount = 0
    }

    struct SpotParts {
        /// A negative unpriced balance (netted debt): spot is no lower bound.
        var hasUnpricedDebt = false
        var unpricedCoins: [String] = []
        var usd: Decimal = 0
    }

    static func lendingParts(_ input: Input, prices: [Int: Decimal]) -> LendingParts {
        var parts = LendingParts()

        for (token, state) in input.borrowLend.tokens {
            let price = prices[token]
            let supply = state.supply.value.value
            let borrow = state.borrow.value.value

            if supply != 0 {
                parts.isActive = true
                parts.lentUSD = price.flatMap { price in parts.lentUSD.map { $0 + supply * price } }
            }

            if borrow != 0 {
                parts.isActive = true
                parts.borrowedUSD = price.flatMap { price in parts.borrowedUSD.map { $0 + borrow * price } }
            }
        }

        return parts
    }

    /// Equity and PnL in each dex's collateral, converted to USD.
    static func perpParts(_ input: Input, prices: [Int: Decimal]) -> PerpParts {
        let collateral = Dictionary(
            input.perpMetas.compactMap { meta in meta.dex.map { ($0, meta.collateralToken) } }
        ) { first, _ in first }

        var parts = PerpParts()

        for (dex, state) in input.clearinghouses {
            let pnl = state.assetPositions.reduce(Decimal.zero) { $0 + $1.position.unrealizedPnl.value }
            let equity = state.marginSummary.accountValue.value
            parts.positionCount += state.assetPositions.count

            guard equity != 0 || pnl != 0 else {
                continue
            }

            parts.hasNonUSDCCollateral = parts.hasNonUSDCCollateral || collateral[dex] != 0

            guard let token = collateral[dex], let price = prices[token] else {
                parts.equityUSD = nil
                parts.isPnlPartial = parts.isPnlPartial || pnl != 0
                continue
            }

            parts.equityUSD = parts.equityUSD.map { $0 + equity * price }
            parts.pnlUSD += pnl * price
        }

        return parts
    }

    static func portfolioValue(_ formula: Formula, parts: Parts) -> HyperliquidPosition.Metric {
        // Signed parts: perp equity (standard). Spot already nets debt.
        let signed: Decimal?
        // Nonnegative parts that may be unpriced.
        var holdings: [Decimal?] = [parts.stakedUSD]

        switch formula {
        case .portfolioMargin:
            signed = 0

        case .standard:
            // Lending and non-USDC collateral in standard mode aren't reconciled yet.
            guard !parts.lending.isActive, !parts.hasNonUSDCCollateral else {
                return HyperliquidPosition.Metric(state: .unavailable, usd: nil)
            }

            signed = parts.perpsUSD

        case .unified:
            // Borrowing in unified mode isn't reconciled yet.
            guard parts.lending.borrowedUSD == 0 else {
                return HyperliquidPosition.Metric(state: .unavailable, usd: nil)
            }

            signed = 0
            holdings.append(parts.lending.lentUSD)

        case .unknown:
            return HyperliquidPosition.Metric(state: .unavailable, usd: nil)
        }

        let priced = parts.spot.usd + parts.vaultsUSD + holdings.compactMap(\.self).reduce(0, +)

        guard let signed, !parts.spot.hasUnpricedDebt else {
            return HyperliquidPosition.Metric(state: .partial, usd: priced + (signed ?? 0))
        }

        let isLowerBound = !parts.spot.unpricedCoins.isEmpty || holdings.contains { $0 == nil }
        return HyperliquidPosition.Metric(state: isLowerBound ? .lowerBound : .complete, usd: priced + signed)
    }

    static func spotParts(_ input: Input, prices: [Int: Decimal]) -> SpotParts {
        var parts = SpotParts()

        for balance in input.spot.balances where balance.total.value != 0 {
            if let token = balance.token, let price = prices[token] {
                parts.usd += balance.total.value * price
            } else {
                parts.unpricedCoins.append(balance.coin)
                parts.hasUnpricedDebt = parts.hasUnpricedDebt || balance.total.value < 0
            }
        }

        return parts
    }
}
