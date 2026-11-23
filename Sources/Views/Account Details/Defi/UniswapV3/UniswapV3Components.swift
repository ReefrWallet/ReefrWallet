//
//  UniswapV3Components.swift
//  Reefr Wallet
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI
import WalletKit

// MARK: - Pair icon

/// Two overlapping token icons with the chain's badge.
struct PairIconView: View {
    let base: UniswapV3Position.Token
    let blockchain: Blockchain
    let quote: UniswapV3Position.Token
    var size: CGFloat = 28

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            HStack(spacing: -size / 3) {
                TokenIconView(token: base, size: size)
                TokenIconView(token: quote, size: size)
            }

            blockchain.networkImage
                .resizable()
                .scaledToFit()
                .padding(2)
                .frame(width: size / 2, height: size / 2)
                .background(Circle().fill(.background))
                .overlay(Circle().stroke(.separator, lineWidth: 0.5))
                .offset(x: 2, y: 2)
        }
        .accessibilityHidden(true)
    }
}

/// A token's bundled logo, its remote image, or its initial.
struct TokenIconView: View {
    let token: UniswapV3Position.Token
    let size: CGFloat

    var body: some View {
        Group {
            if let name = bundledImageName {
                Image(name)
                    .resizable()
                    .scaledToFit()
            } else if let url = token.imageURL {
                WebImageView(url: url)
            } else {
                Text(verbatim: String(token.symbol.prefix(1)))
                    .style(.smallHeader, foreground: .secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Circle().fill(.quaternary))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(.background, lineWidth: 1.5))
    }

    private var bundledImageName: String? {
        let name = "\(token.symbol.lowercased())Token16"
        #if os(macOS)
        return NSImage(named: name) == nil ? nil : name
        #else
        return UIImage(named: name) == nil ? nil : name
        #endif
    }
}

// MARK: - Metric

/// A captioned value; DeFi rows have no column headers.
struct DefiMetric<Value: View>: View {
    let title: LocalizedStringResource
    let value: Value
    let width: CGFloat

    init(_ title: LocalizedStringResource, width: CGFloat, @ViewBuilder value: () -> Value) {
        self.title = title
        self.value = value()
        self.width = width
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(title)
                .style(.small, foreground: .secondary)
            value
        }
        .frame(width: width, alignment: .trailing)
    }
}

// MARK: - Status

struct PositionStatusLabel: View {
    let status: UniswapV3Position.Status

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
        switch status {
        case .inRange: .positive
        case .outOfRange: .caution
        case .withdrawn: .secondary
        }
    }

    private var title: LocalizedStringResource {
        switch status {
        case .inRange: .defiUniswapV3InRange
        case .outOfRange: .defiUniswapV3OutOfRange
        case .withdrawn: .defiUniswapV3Withdrawn
        }
    }
}

// MARK: - Distribution

/// The deployed value split between the two tokens, with the pooled amounts below.
struct LiquidityDistributionBar: View {
    let row: UniswapV3Row

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { proxy in
                let share = row.distribution?.base ?? 0.5

                HStack(spacing: 1) {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: max(proxy.size.width * share - 0.5, 0))
                    Capsule()
                        .fill(Color.accentColor.opacity(0.35))
                }
                .opacity(row.distribution == nil ? 0.3 : 1)
            }
            .frame(height: 6)

            Text(verbatim: row.pooledText)
                .style(.caption, foreground: .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .help(shares ?? "")
        .accessibilityElement(children: .combine)
    }

    /// "89.30% WETH, 10.70% USDC".
    private var shares: String? {
        row.distribution.map { distribution in
            "\(Self.percent(distribution.base)) \(row.base.symbol), \(Self.percent(distribution.quote)) \(row.quote.symbol)"
        }
    }

    private static func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(2)))
    }
}
