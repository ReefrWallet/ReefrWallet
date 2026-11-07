//
//  ReceiveAddressService.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 07.11.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import WalletKit

extension Blockchain {
    /// Chains with an Addresses tab.
    var supportsReceiveAddresses: Bool {
        if case .cardano = self {
            return true
        }

        return false
    }
}

/// Issues Cardano receive addresses offline from the account key. Balances and usage
/// are filled in by ``BalancesService``.
struct ReceiveAddressService {
    let databaseService: DatabaseService

    /// Adds `0/index` as an unchecked row, with no network call. An existing row is kept.
    func add(index: UInt32, to account: Account) async throws {
        guard let accountId = account.id else {
            throw ReefrError.invalidData
        }

        guard index < CardanoAccountDescriptor.addressIndexLimit else {
            throw ReefrError.invalidData
        }

        let descriptor = try CardanoAccountDescriptor(string: account.address)
        let address = try descriptor.address(role: 0, index: index).string

        try await databaseService.insertReceiveAddressIfMissing(accountId: accountId, address: address, index: index)
    }

    /// Row 0, so a new or existing account lists its first address before any discovery.
    func ensureBaseRow(for account: Account) async throws {
        try await add(index: 0, to: account)
    }
}
