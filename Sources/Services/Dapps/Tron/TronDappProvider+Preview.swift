//
//  TronDappProvider+Preview.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 14.10.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation
import WalletKit

/// Best-effort display data for the approval sheet: the called token's
/// symbol/decimals and a fee estimate. Each lookup is bounded and
/// optional — a failure only means less detail, never a blocked prompt.
extension TronDappProvider {
    static let previewLookupTimeout: Duration = .seconds(6)

    func preview(of transaction: TronRawTransaction, account: Account) async -> TronTransactionPreview {
        guard let client = try? clientProvider.tronClient(for: account) else {
            return TronTransactionPreview(transaction: transaction)
        }

        async let token = Self.withTimeout { try await Self.token(called: transaction, client: client) }
        async let fee = Self.withTimeout { try await client.estimateFee(for: transaction) }

        return await TronTransactionPreview(transaction: transaction, token: token ?? nil, fee: fee)
    }

    /// The token a TRC-20 `transfer`/`approve`/`transferFrom` call targets.
    static func token(
        called transaction: TronRawTransaction,
        client: TronClient
    ) async throws -> TronTransactionPreview.Token? {
        guard
            case let .triggerSmartContract(_, contract, _, data) = transaction.contract,
            TronTransactionPreview.knownTokenSelectors.contains(Data(data.prefix(4)))
        else {
            return nil
        }

        let info = try await client.getTokenInfo(contract.string)
        return TronTransactionPreview.Token(decimals: info.decimals, symbol: info.symbol)
    }

    static func withTimeout<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask {
                try? await body()
            }

            group.addTask {
                try? await Task.sleep(for: previewLookupTimeout)
                return nil
            }

            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
