//
//  UniswapV3PositionView.swift
//  Reefr Wallet
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import SwiftUI
import WalletKit

/// One Uniswap V3 LP position as a DeFi table row.
struct UniswapV3PositionView: View {
    let blockchain: Blockchain
    let row: UniswapV3Row?

    init(position: DefiPosition, blockchain: Blockchain) {
        self.blockchain = blockchain
        row = UniswapV3Row(position)
    }

    var body: some View {
        if let row {
            #if os(iOS)
            phoneRow(row)
            #else
            macRow(row)
            #endif
        }
    }
}

private extension UniswapV3PositionView {
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
                    valueLabel(row)
                        .style(.large, foreground: .primary)
                }

                HStack {
                    Text(verbatim: row.feeTier)
                    Spacer()
                    aprLabel(row)
                }
                .style(.callout, foreground: .secondary)

                rangeLabel(row)
                    .style(.callout, foreground: .secondary)

                HStack {
                    PositionStatusLabel(status: row.position.status)
                    Spacer()
                    feesLabel(row)
                }

                custodianLabel(row)

                LiquidityDistributionBar(row: row)
            }
        }
        .padding(.vertical, 6)
        .accessibilityIdentifier("defi-uniswap-row-\(row.position.tokenId)")
    }
    #else
    func macRow(_ row: UniswapV3Row) -> some View {
        HStack(alignment: .center, spacing: 16) {
            HStack(spacing: 10) {
                PairIconView(base: row.base, blockchain: blockchain, quote: row.quote)

                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: row.pairName)
                        .style(.medium, foreground: .primary)
                    Text(verbatim: row.feeTier)
                        .style(.small, foreground: .secondary)
                }
            }
            .frame(width: 180, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                rangeLabel(row)
                    .style(.medium, foreground: .primary)
                    .lineLimit(1)
                PositionStatusLabel(status: row.position.status)
                custodianLabel(row)
            }
            .frame(width: 235, alignment: .leading)

            LiquidityDistributionBar(row: row)
                .frame(minWidth: 160, maxWidth: 260)

            DefiMetric(.defiUniswapV3Value, width: 100) {
                valueLabel(row)
                    .style(.medium, foreground: .primary)
            }

            DefiMetric(.defiUniswapV3Fees, width: 110) {
                feesLabel(row)
            }

            DefiMetric(.defiUniswapV3Apr, width: 60) {
                aprLabel(row)
                    .style(.medium, foreground: .primary)
            }

            DefiMetric(.defiUniswapV3Created, width: 80) {
                historyLabel(row, text: row.createdText)
                    .style(.medium, foreground: .secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("defi-uniswap-row-\(row.position.tokenId)")
    }
    #endif

    /// "Revert Lend collateral" when a protocol holds the NFT.
    @ViewBuilder
    func custodianLabel(_ row: UniswapV3Row) -> some View {
        if let custodian = row.position.custodian, custodian.kind == .revertLend {
            Text(.defiUniswapV3RevertCollateral)
                .style(.small, foreground: .secondary)
                .help(String(localized: .defiUniswapV3CustodianHelp(custodian.vault)))
        }
    }

    @ViewBuilder
    func rangeLabel(_ row: UniswapV3Row) -> some View {
        if row.isFullRange {
            Text(.defiUniswapV3FullRange)
        } else {
            Text(verbatim: row.rangeText)
        }
    }

    func valueLabel(_ row: UniswapV3Row) -> some View {
        Text(verbatim: row.valueText)
            .help(row.unpricedSymbols.map { String(localized: .defiUnpricedTokens($0)) } ?? "")
    }

    func feesLabel(_ row: UniswapV3Row) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            VStack(alignment: .trailing, spacing: 0) {
                ForEach(row.feesLines, id: \.self) { line in
                    Text(verbatim: line)
                }
            }
            .style(isPhone ? .callout : .medium, foreground: .primary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
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
        isPriced: Bool = true,
        ticks: (lower: Int, upper: Int) = (-199_200, -191_100),
        custodian: UniswapV3Position.Custodian? = nil
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

        let current = ticks.lower + tick * (ticks.upper - ticks.lower) / 2 + (ticks.upper - ticks.lower) / 2
        let position = UniswapV3Position(
            apr: history == .complete ? 0.306 : nil,
            chainId: 1,
            createdAt: history == .complete ? .now.addingTimeInterval(-90 * 86_400) : nil,
            custodian: custodian,
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
        .uniswapPreview(id: "5", isPriced: false),
        .uniswapPreview(id: "6", ticks: (-887_270, 887_270)),
        .uniswapPreview(id: "7", custodian: .init(kind: .revertLend, vault: "0x74e6afef5705beb1"))
    ]

    let blockchain = Blockchain.evm(.ethereum(.mainnet))

    #if os(iOS)
    List {
        Section {
            ForEach(positions) { UniswapV3PositionView(position: $0, blockchain: blockchain) }
        } header: {
            Text(.defiUniswapV3Title)
        }
    }
    .listStyle(.plain)
    #else
    Table(of: DefiPosition.self) {
        TableColumn(.defiUniswapV3Title) { UniswapV3PositionView(position: $0, blockchain: blockchain) }
    } rows: {
        Section(.defiUniswapV3Title) {
            ForEach(positions) { TableRow($0) }
        }
    }
    .tableColumnHeaders(.hidden)
    .frame(width: 1_100, height: 560)
    #endif
}
#endif

extension UniswapV3Plugin {
    func view(_ position: DefiPosition) -> some View {
        UniswapV3PositionView(position: position, blockchain: account.blockchain)
    }
}
