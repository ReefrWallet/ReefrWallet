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
}
