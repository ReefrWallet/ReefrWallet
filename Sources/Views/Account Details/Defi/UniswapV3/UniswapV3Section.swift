//
//  UniswapV3Section.swift
//  Reefr Wallet
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import SwiftUI
import WalletKit

/// Uniswap V3 LP positions: a sortable table on Mac, Mail-style rows on iPhone.
struct UniswapV3Section: View {
    let blockchain: Blockchain
    let rows: [UniswapV3Row]

    #if os(macOS)
    @State private var sortOrder = [KeyPathComparator(\UniswapV3Row.sortValue, order: .reverse)]
    #endif

    init(positions: [DefiPosition], blockchain: Blockchain) {
        self.blockchain = blockchain
        rows = positions.compactMap(UniswapV3Row.init)
    }

    var body: some View {
        #if os(iOS)
        Text(.defiUniswapV3Title)
            .style(.smallHeader, foreground: .secondary)
            .listRowSeparator(.hidden)

        ForEach(rows.sorted { $0.sortValue > $1.sortValue }) { row in
            phoneRow(row)
        }
        #else
        VStack(alignment: .leading, spacing: 8) {
            Text(.defiUniswapV3Title)
                .style(.smallHeader, foreground: .secondary)
                .padding(.horizontal)
                .padding(.top, 8)

            Table(rows.sorted(using: sortOrder), sortOrder: $sortOrder) {
                columns
            }
        }
        #endif
    }
}

private extension UniswapV3Section {
    #if os(iOS)
    func phoneRow(_ row: UniswapV3Row) -> some View {
        HStack(alignment: .top, spacing: 12) {
            PairIconView(base: row.base, blockchain: blockchain, quote: row.quote, size: 32)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(verbatim: row.pairName)
                        .style(.headline, foreground: .primary)
                    Spacer()
                    Text(verbatim: row.valueText)
                        .style(.large, foreground: .primary)
                        .help(row.unpricedSymbols.map { String(localized: .defiUnpricedTokens($0)) } ?? "")
                }

                HStack {
                    Text(verbatim: row.feeTier)
                    Spacer()
                    aprLabel(row)
                }
                .style(.callout, foreground: .secondary)

                Text(verbatim: row.rangeText)
                    .style(.callout, foreground: .secondary)

                HStack {
                    PositionStatusLabel(status: row.position.status)
                    Spacer()
                    feesLabel(row)
                }

                LiquidityDistributionBar(row: row)
            }
        }
        .padding(.vertical, 6)
        .accessibilityIdentifier("defi-uniswap-row-\(row.position.tokenId)")
    }
    #else
    @TableColumnBuilder<UniswapV3Row, KeyPathComparator<UniswapV3Row>>
    var columns: some TableColumnContent<UniswapV3Row, KeyPathComparator<UniswapV3Row>> {
        TableColumn(.defiUniswapV3Pool) { row in
            HStack(spacing: 10) {
                PairIconView(base: row.base, blockchain: blockchain, quote: row.quote)

                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: row.pairName)
                        .style(.medium, foreground: .primary)
                    Text(verbatim: row.feeTier)
                        .style(.small, foreground: .secondary)
                }
            }
            .padding(.vertical, 4)
            .accessibilityIdentifier("defi-uniswap-row-\(row.position.tokenId)")
        }
        .width(min: 150, ideal: 190)

        TableColumn(.defiUniswapV3Position) { row in
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: row.rangeText)
                    .style(.medium, foreground: .primary)
                PositionStatusLabel(status: row.position.status)
            }
        }
        .width(min: 180, ideal: 230)

        TableColumn(.defiUniswapV3Distribution) { row in
            LiquidityDistributionBar(row: row)
        }
        .width(min: 140, ideal: 200)

        TableColumn(.defiUniswapV3Value, value: \.sortValue) { row in
            Text(verbatim: row.valueText)
                .style(.medium, foreground: .primary)
                .help(row.unpricedSymbols.map { String(localized: .defiUnpricedTokens($0)) } ?? "")
        }
        .width(min: 80, ideal: 110)

        TableColumn(.defiUniswapV3Fees, value: \.sortFees) { row in
            feesLabel(row)
        }
        .width(min: 80, ideal: 110)

        TableColumn(.defiUniswapV3Apr, value: \.sortAPR) { row in
            aprLabel(row)
                .style(.medium, foreground: .primary)
        }
        .width(min: 60, ideal: 80)

        TableColumn(.defiUniswapV3Created, value: \.sortCreated) { row in
            historyLabel(row, text: row.createdText)
                .style(.medium, foreground: .secondary)
        }
        .width(min: 80, ideal: 100)
    }
    #endif

    func feesLabel(_ row: UniswapV3Row) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(verbatim: row.feesText)
                .style(isPhone ? .callout : .medium, foreground: .primary)
                .help(row.lifetimeFeesText.map { String(localized: .defiUniswapV3LifetimeFees($0)) } ?? "")

            if let claimable = row.claimableText {
                Text(.defiUniswapV3Claimable(claimable))
                    .style(.small, foreground: .secondary)
                    .help(String(localized: .defiUniswapV3ClaimableHelp))
            }
        }
    }

    func aprLabel(_ row: UniswapV3Row) -> some View {
        historyLabel(row, text: row.aprText)
            .help(String(localized: .defiUniswapV3AprHelp))
    }

    @ViewBuilder
    func historyLabel(_ row: UniswapV3Row, text: String?) -> some View {
        if let text {
            Text(verbatim: text)
        } else if row.position.historyState == .loading {
            ProgressView()
                .controlSize(.mini)
                .help(String(localized: .defiUniswapV3LoadingHistory))
        } else {
            let help = row.position.historyState == .unavailable
                ? String(localized: .defiUniswapV3HistoryUnavailable)
                : ""

            Text(verbatim: "—")
                .help(help)
        }
    }
}

#if DEBUG
extension DefiPosition {
    /// A WETH/USDC position for previews.
    static func uniswapPreview(
        id: String,
        tick: Int = 0,
        liquidity: Int = 1,
        history: UniswapV3Position.HistoryState = .complete,
        isPriced: Bool = true
    ) -> DefiPosition {
        let weth = UniswapV3Position.Token(
            address: "0x1", decimals: 18, imageURL: nil, priceAt: .now, symbol: "WETH", usdPrice: isPriced ? 3_000 : nil
        )

        let usdc = UniswapV3Position.Token(
            address: "0x2",
            decimals: 6,
            imageURL: nil,
            priceAt: .now,
            symbol: "USDC",
            usdPrice: 1
        )

        let ticks = (lower: -199_200, upper: -191_100)
        let current = ticks.lower + tick * (ticks.upper - ticks.lower) / 2 + (ticks.upper - ticks.lower) / 2
        let position = UniswapV3Position(
            apr: history == .complete ? 0.306 : nil,
            chainId: 1,
            createdAt: history == .complete ? .now.addingTimeInterval(-90 * 86_400) : nil,
            deployed: .init(BigUInt(5) * BigUInt(10).power(17), 39_000_000),
            deployedUSD: 1_539,
            fee: 500,
            fees: .init(BigUInt(3) * BigUInt(10).power(15), 10_440_000),
            feesUSD: 19.44,
            history: .empty,
            historyState: history,
            isFeesExact: true,
            lifetimeFees: nil,
            liquidity: String(liquidity),
            pendingFees: .zero,
            pinned: BlockRef(hash: "0x0", number: 1, timestamp: .now),
            priceCurrent: UniswapV3Math.price(atTick: current, decimals0: 18, decimals1: 6),
            priceLower: UniswapV3Math.price(atTick: ticks.lower, decimals0: 18, decimals1: 6),
            priceUpper: UniswapV3Math.price(atTick: ticks.upper, decimals0: 18, decimals1: 6),
            tickCurrent: current,
            tickLower: ticks.lower,
            tickUpper: ticks.upper,
            token0: weth,
            token1: usdc,
            tokenId: id,
            tokensOwed: liquidity == 0 ? .init(BigUInt(10).power(17), 0) : .zero,
            valueUSD: isPriced ? 1_598.47 : nil
        )

        return DefiPosition(
            id: id,
            isUSDValueComplete: isPriced,
            key: "1:\(id)",
            kind: .uniswapV3,
            payload: (try? position.encoded()) ?? Data(),
            updatedAt: .now,
            usdValue: isPriced ? 1_598.47 : 39
        )
    }
}

#Preview("Uniswap V3") {
    let positions: [DefiPosition] = [
        .uniswapPreview(id: "1"),
        .uniswapPreview(id: "2", tick: 2),
        .uniswapPreview(id: "3", liquidity: 0),
        .uniswapPreview(id: "4", history: .loading),
        .uniswapPreview(id: "5", isPriced: false)
    ]

    #if os(iOS)
    List {
        UniswapV3Section(positions: positions, blockchain: .evm(.ethereum(.mainnet)))
    }
    .listStyle(.plain)
    #else
    UniswapV3Section(positions: positions, blockchain: .evm(.ethereum(.mainnet)))
        .frame(width: 1_100, height: 420)
    #endif
}
#endif
