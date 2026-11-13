//
//  TonSendService.swift
//  Reefr Wallet
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation
import WalletKit

/// A mutex for async code: unlike an actor, it holds across `await`s.
private actor SendLock {
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard isHeld else {
            isHeld = true
            return
        }

        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            isHeld = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// Submits TON transfers so a wallet's `seqno` is used at most once and an unknown outcome is never
/// answered with a second signature.
///
/// The signed message is stored as a broadcast placeholder (its identifier is the message's normalized hash,
/// the one history reports) before it is submitted, so it survives a restart. Another send is refused while
/// an earlier one may still be processed.
final class TonSendService: @unchecked Sendable {
    private lazy var clientProvider = DI.injectOrFail(BlockchainClientProvider.self)
    private let databaseService: DatabaseService
    /// Shared, so every instance serializes sends against the same `seqno`.
    private static let lock = SendLock()
    private var lock: SendLock { Self.lock }

    init(databaseService: DatabaseService? = nil) {
        self.databaseService = databaseService ?? DI.injectOrFail(DatabaseService.self)
    }

    /// Throws ``TonSendError/unresolvedPendingSend`` if an earlier send from `account` may still be processed.
    func ensureCanSend(account: Account) async throws {
        await lock.acquire()
        defer { Task { await lock.release() } }
        try await resolve(account, throwing: true)
    }

    /// Stores, submits and returns the normalized hash of the signed `txRequest`.
    ///
    /// A definite rejection is thrown and nothing is kept. After an ambiguous failure the placeholder stays and
    /// the hash is returned: ``reconcile(account:)`` settles it later.
    func send(_ txRequest: Data, signature: Data, account: Account) async throws -> String {
        await lock.acquire()
        defer { Task { await lock.release() } }

        let envelope = try JSONDecoder().decode(TonUnsignedTransaction.self, from: txRequest)
        let pending = try envelope.pendingSend(signature: signature)
        let client = try client(for: account)

        try await resolve(account, throwing: true)
        try await databaseService.saveTransactions([placeholder(for: envelope, pending: pending)], for: account)

        do {
            try await client.submit(pending)
        } catch {
            guard TonClient.isAmbiguous(error) else {
                _ = try? await databaseService.removeBroadcastPlaceholder(
                    identifier: pending.normalizedHash,
                    for: account
                )

                throw error
            }

            printError("TON submit outcome unknown, will reconcile: \(error)")
        }

        return pending.normalizedHash
    }

    /// Settles stored sends: resends current ones, drops those that can no longer be processed.
    func reconcile(account: Account) async {
        await lock.acquire()
        defer { Task { await lock.release() } }

        do {
            try await resolve(account, throwing: false)
        } catch {
            printError("\(account.name): \(error)")
        }
    }

    // MARK: Private

    private func client(for account: Account) throws -> TonClient {
        guard let client = try clientProvider.makeClient(
            blockchain: account.blockchain,
            rpcURL: account.rpcURLOverride
        ) as? TonClient else {
            throw ReefrError.invalidData
        }

        return client
    }

    /// Checks every stored send. With `throwing`, one that may still be processed (or can't be checked) is an error.
    private func resolve(_ account: Account, throwing: Bool) async throws {
        guard let accountId = account.id else {
            throw ReefrError.invalidData
        }

        let client = try client(for: account)
        let stored = try await databaseService.fetchBroadcastTransactions(accountId: accountId)

        for transaction in stored {
            guard let payload = transaction.rawPayload,
                  let pending = try? JSONDecoder().decode(TonPendingSend.self, from: payload)
            else {
                continue
            }

            switch try await client.reconcile(pending) {
            case .confirmed:
                continue
            case .pending, .unresolved:
                if throwing {
                    throw TonSendError.unresolvedPendingSend
                }

            case .unprocessed:
                try await databaseService.removeBroadcastPlaceholder(
                    identifier: pending.normalizedHash,
                    for: account
                )
            }
        }
    }

    private func placeholder(
        for envelope: TonUnsignedTransaction,
        pending: TonPendingSend
    ) throws -> BlockchainTransaction {
        BlockchainTransaction(
            identifier: pending.normalizedHash,
            sender: envelope.sender,
            recipient: envelope.recipient,
            status: .broadcast,
            rawPayload: try JSONEncoder().encode(pending),
            effects: [
                BlockchainTransactionEffect(
                    index: 0,
                    kind: .nativeTransfer,
                    amount: envelope.value,
                    from: envelope.sender,
                    to: envelope.recipient
                )
            ],
            method: "Transfer"
        )
    }
}
