//
//  Decimal+Extensions.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 02.11.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation

extension Decimal {
    /// Up to six fraction digits followed by `symbol`, e.g. "1.5 ADA".
    func formatted(symbol: String) -> String {
        let amount = formatted(.number.precision(.fractionLength(0...6)))
        return String(localized: .commonAmountWithSymbol(amount, symbol))
    }

    /// From 100,000 abbreviated with up to two fraction digits ("945.5 K", "5.45 M", "2 B"); otherwise
    /// two fraction digits, or `fractionLength` if given. No currency symbol.
    func formattedAbbreviated(fractionLength: Int = 2) -> String {
        let magnitude = abs(self)
        // swiftlint:disable:next large_tuple
        let tiers: [(threshold: Decimal, divisor: Decimal, suffix: String)] = [
            (1_000_000_000, 1_000_000_000, "B"),
            (1_000_000, 1_000_000, "M"),
            (100_000, 1_000, "K")
        ]

        guard let tier = tiers.first(where: { magnitude >= $0.threshold }) else {
            return formatted(.number.precision(.fractionLength(fractionLength)))
        }

        return "\((self / tier.divisor).formatted(.number.precision(.fractionLength(0...2)))) \(tier.suffix)"
    }
}
