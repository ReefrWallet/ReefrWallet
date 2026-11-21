//
//  BalancesService+Ton.swift
//  Reefr Wallet
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import WalletKit

extension BalancesService {
    /// The held tokens (non-zero stored balance) whose snapshot entry is absent or zero, by their stored address.
    static func unprovenHoldings(_ held: [(address: String, amount: BigUInt)], listed: [String: BigUInt]) -> [String] {
        held.compactMap { holding in
            guard holding.amount != 0, let identity = tonIdentity(holding.address) else {
                return nil
            }

            return (listed[identity] ?? 0) == 0 ? holding.address : nil
        }
    }

    /// The amounts `read` returns per address; an address whose read fails is left out.
    static func readOnChain(
        _ addresses: [String],
        read: (String) async throws -> BigUInt
    ) async -> [String: BigUInt] {
        var amounts: [String: BigUInt] = [:]

        for address in addresses {
            do {
                amounts[address] = try await read(address)
            } catch {
                printError("on-chain balance of \(address) unavailable, keeping the stored one: \(error)")
            }
        }

        return amounts
    }

    /// A TON address is case-sensitive and carries flags, so it is compared by workchain and hash.
    static func tonIdentity(_ address: String) -> String? {
        guard let parsed = try? TonAddress(string: address) else {
            return nil
        }

        return "\(parsed.workchain):\(parsed.hash.map { String(format: "%02x", $0) }.joined())"
    }
}
