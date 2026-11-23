//
//  HyperliquidPositionView.swift
//  Reefr Wallet
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI

/// HyperCore Portfolio Value and Unrealized PnL for the account, as a DeFi table row. See ADR-074.
struct HyperliquidPositionView: View {
    let position: HyperliquidPosition?

    init(position: DefiPosition) {
        self.position = try? position.payload.decoded()
    }

    var body: some View {
        if let position {
            #if os(iOS)
            VStack(alignment: .leading, spacing: 8) {
                testnetLabel(position)
                metricRow(.defiHyperliquidPortfolioValue, metric: position.portfolioValue, isSigned: false)
                    .accessibilityIdentifier("defi-hyperliquid-portfolio-value")
                metricRow(.defiHyperliquidUnrealizedPnl, metric: position.unrealizedPnl, isSigned: true)
                    .accessibilityIdentifier("defi-hyperliquid-unrealized-pnl")
            }
            .padding(.vertical, 6)
            #else
            VStack(alignment: .leading, spacing: 8) {
                testnetLabel(position)

                HStack(alignment: .top, spacing: 32) {
                    metricColumn(.defiHyperliquidPortfolioValue, metric: position.portfolioValue, isSigned: false)
                        .accessibilityIdentifier("defi-hyperliquid-portfolio-value")
                    metricColumn(.defiHyperliquidUnrealizedPnl, metric: position.unrealizedPnl, isSigned: true)
                        .accessibilityIdentifier("defi-hyperliquid-unrealized-pnl")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            #endif
        }
    }
}

private extension HyperliquidPositionView {
    @ViewBuilder
    func testnetLabel(_ position: HyperliquidPosition) -> some View {
        if position.network == .testnet {
            Text(.defiHyperliquidTestnet)
                .style(.small, foreground: .secondary)
        }
    }

    #if os(iOS)
    func metricRow(_ title: LocalizedStringResource, metric: HyperliquidPosition.Metric, isSigned: Bool) -> some View {
        HStack {
            Text(title)
                .style(.callout, foreground: .secondary)
            Spacer()
            metricValue(metric, isSigned: isSigned, size: .large)
        }
    }
    #else
    func metricColumn(
        _ title: LocalizedStringResource,
        metric: HyperliquidPosition.Metric,
        isSigned: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .style(.small, foreground: .secondary)
            metricValue(metric, isSigned: isSigned, size: .mediumHeader)
        }
    }
    #endif

    func metricValue(_ metric: HyperliquidPosition.Metric, isSigned: Bool, size: StyledView.Size) -> some View {
        HStack(spacing: 4) {
            Text(verbatim: Self.text(metric, isSigned: isSigned))
                .style(size, foreground: Self.color(metric, isSigned: isSigned))

            if let help = Self.help(metric, unpricedCoins: position?.unpricedCoins ?? []) {
                Image(systemName: "exclamationmark.circle")
                    .style(size, foreground: .secondary)
                    .help(help)
                    .accessibilityLabel(Text(verbatim: help))
            }
        }
    }

    static func color(_ metric: HyperliquidPosition.Metric, isSigned: Bool) -> Color {
        guard isSigned, metric.state == .complete, let usd = metric.usd, usd != 0 else {
            return .primary
        }

        return usd > 0 ? .positive : .negative
    }

    static func help(_ metric: HyperliquidPosition.Metric, unpricedCoins: [String]) -> String? {
        switch metric.state {
        case .complete:
            nil
        case .lowerBound:
            unpricedCoins.isEmpty
                ? nil
                : String(localized: .defiUnpricedTokens(unpricedCoins.formatted(.list(type: .and))))
        case .partial:
            String(localized: .defiHyperliquidPartial)
        case .unavailable:
            String(localized: .defiHyperliquidUnavailable)
        }
    }

    /// "1.2 K US$", "+/−" for PnL, "—" when unknown.
    static func text(_ metric: HyperliquidPosition.Metric, isSigned: Bool) -> String {
        guard let usd = metric.usd, metric.state != .unavailable else {
            return "—"
        }

        let sign = isSigned && usd > 0 ? "+" : ""
        return "\(sign)\(usd.formattedAbbreviated()) US$"
    }
}

extension HyperliquidPlugin {
    func view(_ position: DefiPosition) -> some View {
        HyperliquidPositionView(position: position)
    }
}
