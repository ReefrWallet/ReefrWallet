//
//  PartialBalanceUpdateError.swift
//  Reefr Wallet
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

/// Some balance requests failed; the rest were persisted.
struct PartialBalanceUpdateError: Swift.Error, CustomStringConvertible {
    let errors: [any Swift.Error]

    var description: String {
        "\(errors.count) balance request(s) failed: \(errors)"
    }
}
