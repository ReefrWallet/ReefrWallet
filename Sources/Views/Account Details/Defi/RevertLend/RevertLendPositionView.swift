//
//  RevertLendPositionView.swift
//  Reefr Wallet
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import SwiftUI
import WalletKit

/// A Revert Lend loan or deposit as a DeFi table row. See ADR-075.
struct RevertLendPositionView: View {
    let blockchain: Blockchain
    let position: RevertLendPosition?

    init(position: DefiPosition, blockchain: Blockchain) {
        self.blockchain = blockchain
        self.position = try? position.payload.decoded()
    }

    var body: some View {
        switch position {
        case let .deposit(deposit):
            depositRow(deposit)
        case let .loan(loan):
            loanRow(loan)
        case nil:
            EmptyView()
        }
    }
}

// MARK: - Loan

private extension RevertLendPositionView {
    func loanRow(_ loan: RevertLendPosition.Loan) -> some View {
        #if os(iOS)
        phoneLoanRow(loan, pair: UniswapV3Row.pair(loan.token0, loan.token1))
        #else
        macLoanRow(loan, pair: UniswapV3Row.pair(loan.token0, loan.token1))
        #endif
    }

    typealias Pair = (base: UniswapV3Position.Token, quote: UniswapV3Position.Token)

    #if os(iOS)
    func phoneLoanRow(_ loan: RevertLendPosition.Loan, pair: Pair) -> some View {
        HStack(alignment: .top, spacing: 12) {
            PairIconView(base: pair.base, blockchain: blockchain, quote: pair.quote, size: 32)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(verbatim: UniswapV3Row.pairName(loan.token0, loan.token1))
                        .style(.headline, foreground: .primary)
                    Spacer()
                    Text(verbatim: debtText(loan))
                        .style(.large, foreground: .primary)
                }

                HStack {
                    Text(.defiRevertLendPosition(loan.tokenId))
                    Spacer()
                    aprText(loan.borrowAPR, title: .defiRevertLendBorrowApr)
                }
                .style(.callout, foreground: .secondary)

                HStack {
                    LoanHealthLabel(loan: loan)
                    Spacer()
                    Text(.defiRevertLendHealth)
                        .style(.callout, foreground: .secondary)
                    healthValue(loan)
                        .style(.callout, foreground: .primary)
                }
            }
        }
        .padding(.vertical, 6)
        .accessibilityIdentifier("defi-revert-loan-\(loan.tokenId)")
    }
    #else
    func macLoanRow(_ loan: RevertLendPosition.Loan, pair: Pair) -> some View {
        HStack(alignment: .center, spacing: 16) {
            HStack(spacing: 10) {
                PairIconView(base: pair.base, blockchain: blockchain, quote: pair.quote)

                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: UniswapV3Row.pairName(loan.token0, loan.token1))
                        .style(.medium, foreground: .primary)
                    Text(verbatim: UniswapV3Row.feeTier(loan.fee))
                        .style(.small, foreground: .secondary)
                }
            }
            .frame(width: 180, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(.defiRevertLendPosition(loan.tokenId))
                    .style(.medium, foreground: .primary)
                LoanHealthLabel(loan: loan)
            }
            .frame(width: 235, alignment: .leading)

            Spacer(minLength: 160)

            DefiMetric(.defiRevertLendDebt, width: 100) {
                Text(verbatim: debtText(loan))
                    .style(.medium, foreground: .primary)
            }

            DefiMetric(.defiRevertLendHealth, width: 110) {
                healthValue(loan)
                    .style(.medium, foreground: .primary)
            }

            DefiMetric(.defiRevertLendLtv, width: 60) {
                Text(verbatim: loan.loanToValue.map(Self.percent) ?? "—")
                    .style(.medium, foreground: .primary)
            }

            DefiMetric(.defiRevertLendBorrowApr, width: 80) {
                Text(verbatim: loan.borrowAPR.map(Self.percent) ?? "—")
                    .style(.medium, foreground: .primary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("defi-revert-loan-\(loan.tokenId)")
    }
    #endif

    func debtText(_ loan: RevertLendPosition.Loan) -> String {
        UniswapV3Row.usd(loan.asset.usdValue(loan.debtAmount) ?? loan.asset.decimalAmount(loan.debtAmount))
    }

    /// "1.85", or "—" without debt; the collateral value in its help.
    func healthValue(_ loan: RevertLendPosition.Loan) -> some View {
        let collateral = UniswapV3Row.usd(loan.asset.decimalAmount(loan.collateralValueAmount))

        return Text(verbatim: loan.health.map { $0.formatted(.number.precision(.fractionLength(2))) } ?? "—")
            .help(String(localized: .defiRevertLendHealthHelp(collateral)))
    }
}

// MARK: - Deposit

private extension RevertLendPositionView {
    @ViewBuilder
    func depositRow(_ deposit: RevertLendPosition.Deposit) -> some View {
        let amount = deposit.asset.decimalAmount(deposit.amountValue).formatted(symbol: deposit.asset.symbol)
        let value = UniswapV3Row.usd(deposit.asset.usdValue(deposit.amountValue) ?? 0)

        #if os(iOS)
        HStack(alignment: .top, spacing: 12) {
            TokenIconView(token: deposit.asset, size: 32)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(.defiRevertLendDeposit(deposit.asset.symbol))
                        .style(.headline, foreground: .primary)
                    Spacer()
                    Text(verbatim: value)
                        .style(.large, foreground: .primary)
                }

                HStack {
                    Text(verbatim: amount)
                    Spacer()
                    aprText(deposit.supplyAPR, title: .defiRevertLendSupplyApr)
                }
                .style(.callout, foreground: .secondary)
            }
        }
        .padding(.vertical, 6)
        .accessibilityIdentifier("defi-revert-deposit")
        #else
        HStack(alignment: .center, spacing: 16) {
            HStack(spacing: 10) {
                TokenIconView(token: deposit.asset, size: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(.defiRevertLendDeposit(deposit.asset.symbol))
                        .style(.medium, foreground: .primary)
                    Text(verbatim: amount)
                        .style(.small, foreground: .secondary)
                }
            }
            .frame(width: 180, alignment: .leading)

            Spacer()

            DefiMetric(.defiUniswapV3Value, width: 100) {
                Text(verbatim: value)
                    .style(.medium, foreground: .primary)
            }

            DefiMetric(.defiRevertLendSupplyApr, width: 80) {
                Text(verbatim: deposit.supplyAPR.map(Self.percent) ?? "—")
                    .style(.medium, foreground: .primary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("defi-revert-deposit")
        #endif
    }
}

// MARK: - Shared

private extension RevertLendPositionView {
    /// "Borrow APR 8.20%".
    func aprText(_ apr: Decimal?, title: LocalizedStringResource) -> some View {
        HStack(spacing: 4) {
            Text(title)
            Text(verbatim: apr.map(Self.percent) ?? "—")
        }
    }

    static func percent(_ value: Decimal) -> String {
        value.formatted(.percent.precision(.fractionLength(2)))
    }
}

/// Healthy, at risk (health below 1.2), liquidatable (below 1), or no debt.
struct LoanHealthLabel: View {
    static let riskThreshold: Decimal = 1.2

    let loan: RevertLendPosition.Loan

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)

            Text(title)
                .style(.callout, foreground: color)
        }
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        guard let health = loan.health else {
            return .secondary
        }

        if health < 1 {
            return .negative
        }

        return health < Self.riskThreshold ? .caution : .positive
    }

    private var title: LocalizedStringResource {
        guard let health = loan.health else {
            return .defiRevertLendNoDebt
        }

        if health < 1 {
            return .defiRevertLendLiquidatable
        }

        return health < Self.riskThreshold ? .defiRevertLendAtRisk : .defiRevertLendHealthy
    }
}

#if DEBUG
extension DefiPosition {
    /// A WETH/USDC loan with `debt` US$ against 1,600 US$ of collateral, for previews.
    static func revertLoanPreview(id: String, debt: Decimal) -> DefiPosition {
        let usdc = UniswapV3Position.Token(
            address: "0x2", decimals: 6, imageURL: nil, priceAt: .now, symbol: "USDC", usdPrice: 1
        )

        let weth = UniswapV3Position.Token(
            address: "0x1", decimals: 18, imageURL: nil, priceAt: .now, symbol: "WETH", usdPrice: 3_000
        )

        let units = { (usd: Decimal) in String(describing: NSDecimalNumber(decimal: usd * 1_000_000).intValue) }
        let loan = RevertLendPosition.Loan(
            asset: usdc,
            borrowAPR: 0.082,
            chainId: 42_161,
            collateralValue: units(1_200),
            debt: units(debt),
            fee: 500,
            fullValue: units(1_600),
            liquidationCost: "0",
            token0: weth,
            token1: usdc,
            tokenId: id,
            vault: "0x74e6afef5705beb126c6d3bf46f8fad8f3e07825"
        )

        let position = RevertLendPosition.loan(loan)

        return DefiPosition(
            id: id,
            key: position.key,
            kind: .revertLend,
            payload: (try? position.encoded()) ?? Data(),
            updatedAt: .now,
            usdValue: position.usdValue
        )
    }

    static let revertDepositPreview: DefiPosition = {
        let usdc = UniswapV3Position.Token(
            address: "0x2", decimals: 6, imageURL: nil, priceAt: .now, symbol: "USDC", usdPrice: 1
        )

        let position = RevertLendPosition.deposit(
            .init(amount: "2500000000", asset: usdc, supplyAPR: 0.061, vault: "0x74e6")
        )

        return DefiPosition(
            id: "deposit",
            key: position.key,
            kind: .revertLend,
            payload: (try? position.encoded()) ?? Data(),
            updatedAt: .now,
            usdValue: position.usdValue
        )
    }()
}

#Preview("Revert Lend") {
    let positions: [DefiPosition] = [
        .revertLoanPreview(id: "1", debt: 500),
        .revertLoanPreview(id: "2", debt: 1_100),
        .revertLoanPreview(id: "3", debt: 1_300),
        .revertLoanPreview(id: "4", debt: 0),
        .revertDepositPreview
    ]

    let blockchain = Blockchain.evm(.arbitrum(.mainnet))

    #if os(iOS)
    List {
        Section {
            ForEach(positions) { RevertLendPositionView(position: $0, blockchain: blockchain) }
        } header: {
            Text(.defiRevertLendTitle)
        }
    }
    .listStyle(.plain)
    #else
    Table(of: DefiPosition.self) {
        TableColumn(.defiRevertLendTitle) { RevertLendPositionView(position: $0, blockchain: blockchain) }
    } rows: {
        Section(.defiRevertLendTitle) {
            ForEach(positions) { TableRow($0) }
        }
    }
    .tableColumnHeaders(.hidden)
    .frame(width: 1_100, height: 460)
    #endif
}
#endif

extension RevertLendPlugin {
    func view(_ position: DefiPosition) -> some View {
        RevertLendPositionView(position: position, blockchain: account.blockchain)
    }
}
