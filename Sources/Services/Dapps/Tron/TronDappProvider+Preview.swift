//
//  TronDappProvider+Preview.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 14.10.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation
import os
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
        let feeStartedAt = Date()
        async let fee = Self.withTimeout { try await client.estimateFee(for: transaction) }

        let estimate = await fee

        if let resources = estimate?.resources {
            await DI.inject(TronStakingPositionLoader.self)?
                .record(resources: resources, startedAt: feeStartedAt, account: account)
        }

        return await TronTransactionPreview(transaction: transaction, token: token ?? nil, fee: estimate)
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

    /// `body`'s result, or `nil` after `previewLookupTimeout`. Doesn't wait
    /// for `body` to honour cancellation (network retries may not).
    static func withTimeout<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async -> T? {
        let pending = OSAllocatedUnfairLock<CheckedContinuation<T?, Never>?>(initialState: nil)
        let resume: @Sendable (T?) -> Void = { value in
            pending.withLock { $0.take() }?.resume(returning: value)
        }

        return await withCheckedContinuation { continuation in
            pending.withLock { $0 = continuation }
            let work = Task {
                resume(try? await body())
            }

            Task {
                try? await Task.sleep(for: previewLookupTimeout)
                work.cancel()
                resume(nil)
            }
        }
    }
}
