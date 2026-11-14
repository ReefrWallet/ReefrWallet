//
//  TonSendService.swift
//  Reefr Wallet
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation
import SwiftData
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
/// an earlier one may still be processed, and a request signed for a `seqno` the wallet has since used is
/// refused.
final class TonSendService: @unchecked Sendable {
    private lazy var clientProvider = DI.injectOrFail(BlockchainClientProvider.self)
    private let databaseService: DatabaseService
    /// Where each account's next delivery pass starts; guarded by ``lock``.
    private var deliveryOffsets: [PersistentIdentifier: Int] = [:]
    /// Open deliveries checked per pass, rotating through all of them, so a long history doesn't flood the indexer.
    private static let deliveriesPerPass = 10
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

        // Requests are built and signed outside the lock, so two can carry the same `seqno`. Only one may go out.
        guard try await client.seqno(TonAddress(string: envelope.sender)) == envelope.seqno else {
            throw TonSendError.staleRequest
        }

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

        await trackDeliveries(account)
    }

    // MARK: Private

    /// A confirmed sender transaction only proves the wallet emitted the message. Checks the recipient's side of
    /// sends still open, however old, apart from the history cursor, and stores the outcome once it is final.
    private func trackDeliveries(_ account: Account) async {
        guard let accountId = account.id, let client = try? client(for: account) else {
            return
        }

        do {
            let all = try await databaseService.fetchUndecidedDeliveries(accountId: accountId)
            let offset = deliveryOffsets[accountId] ?? 0
            deliveryOffsets[accountId] = offset + Self.deliveriesPerPass

            await Self.settle(
                Self.rotating(all, from: offset, count: Self.deliveriesPerPass),
                lookup: { try await client.deliveryStatus(ofOutgoingMessage: $0) },
                record: { try await databaseService.recordDelivery(stableId: $0, outcome: $1) },
                onFailure: { printError("\(account.name): delivery check: \($0)") }
            )
        } catch {
            printError("\(account.name): delivery check: \(error)")
        }
    }

    /// Looks up each send and stores a final outcome. A failure on one send doesn't stop the rest.
    static func settle(
        _ sends: [(stableId: String, reference: TonDeliveryReference)],
        lookup: (String) async throws -> TonDeliveryStatus,
        record: (String, TonDeliveryReference.Outcome) async throws -> Void,
        onFailure: (any Error) -> Void
    ) async {
        for (stableId, reference) in sends {
            do {
                switch try await lookup(reference.outMessageHash) {
                case .bounced, .failed: try await record(stableId, .failed)
                case .delivered: try await record(stableId, .delivered)
                case .pending: continue
                }
            } catch {
                onFailure(error)
            }
        }
    }

    /// Up to `count` items starting at `offset`, wrapping around, so successive passes cover every open send.
    static func rotating<Element>(_ items: [Element], from offset: Int, count: Int) -> [Element] {
        guard !items.isEmpty else {
            return []
        }

        return (0 ..< min(count, items.count)).map { items[(offset + $0) % items.count] }
    }

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
