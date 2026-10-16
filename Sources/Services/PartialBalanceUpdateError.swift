//
//  PartialBalanceUpdateError.swift
//  Reefr Wallet
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation

/// Some balance requests failed; the rest were persisted.
struct PartialBalanceUpdateError: LocalizedError, CustomStringConvertible {
    let errors: [any Swift.Error]

    var description: String {
        "\(errors.count) balance request(s) failed: \(errors)"
    }

    var errorDescription: String? {
        "\(errors.count) balance request(s) failed: "
            + errors.map(\.localizedDescription).joined(separator: "; ")
    }
}
