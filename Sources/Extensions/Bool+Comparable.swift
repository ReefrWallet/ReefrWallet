//
//  Bool+Comparable.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 13.02.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

extension Bool: @retroactive Comparable {
    public static func < (lhs: Bool, rhs: Bool) -> Bool {
        rhs && !lhs
    }
}
