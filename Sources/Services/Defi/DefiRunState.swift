//
//  DefiRunState.swift
//  Reefr Wallet
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation

/// The number of expensive requests (history log queries) one run may make.
actor DefiRequestBudget {
    private(set) var remaining: Int

    init(_ limit: Int) {
        remaining = limit
    }

    /// Takes one request from the budget; `false` once it's spent.
    func spend() -> Bool {
        guard remaining > 0 else {
            return false
        }

        remaining -= 1
        return true
    }
}

/// Counts a plugin's runs, so each starts handing out the budget at another
/// position and one long backfill can't starve the rest.
actor DefiRunCounter {
    private var count = 0

    func next() -> Int {
        defer {
            count &+= 1
        }

        return count
    }
}
