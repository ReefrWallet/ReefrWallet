//
//  DatabaseService+TransactionDelivery.swift
//  ReefrWallet
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftData
import WalletKit

extension DatabaseService {
    /// The account's confirmed sends whose recipient-side outcome is still open, newest first.
    func fetchUndecidedDeliveries(
        accountId: PersistentIdentifier
    ) throws -> [(stableId: String, reference: TonDeliveryReference)] {
        // A Jetton request stays unconfirmed until its trace credits the recipient.
        let confirmed = BlockchainTransactionStatus.confirmed.rawValue
        let unconfirmed = BlockchainTransactionStatus.unconfirmed.rawValue
        let predicate = #Predicate<WalletTransactionModel> {
            $0.account.persistentModelID == accountId && ($0.status == confirmed || $0.status == unconfirmed)
                && $0.rawPayload != nil
        }

        return try modelContext.fetch(FetchDescriptor(predicate: predicate))
            .sorted { ($0.timestamp ?? .distantPast) > ($1.timestamp ?? .distantPast) }
            .compactMap { model -> (stableId: String, reference: TonDeliveryReference)? in
                guard var reference = Self.deliveryReference(model.rawPayload), reference.outcome == nil
                else {
                    return nil
                }

                if reference.isJettonRequest == true {
                    Self.attachJetton(of: model, to: &reference)
                }

                return (model.stableId, reference)
            }
    }

    /// Stores the recipient-side outcome of `stableId`. A failure also sets the entry's status.
    func recordDelivery(stableId: String, outcome: TonDeliveryReference.Outcome) throws {
        var descriptor = FetchDescriptor(predicate: #Predicate<WalletTransactionModel> { $0.stableId == stableId })
        descriptor.fetchLimit = 1

        guard let model = try modelContext.fetch(descriptor).first,
              var reference = Self.deliveryReference(model.rawPayload)
        else {
            return
        }

        reference.outcome = outcome
        model.rawPayload = try reference.encoded()

        model.status = (outcome == .failed ? BlockchainTransactionStatus.failed : .confirmed).rawValue

        try modelContext.save()
    }

    /// The status and payload to store when a history import meets `existing`: a recorded recipient outcome
    /// outlives the sender-side entry being re-imported as plain `confirmed`.
    static func preservingDelivery(
        incoming: (status: BlockchainTransactionStatus, payload: Data?),
        existing: (status: String, payload: Data?)
    ) -> (status: BlockchainTransactionStatus, payload: Data?) {
        let incoming = carryingJettonIntent(incoming, from: existing.payload)

        guard let kept = deliveryReference(existing.payload),
              let outcome = kept.outcome,
              let fresh = deliveryReference(incoming.payload),
              fresh.outMessageHash == kept.outMessageHash
        else {
            return incoming
        }

        return (outcome == .failed ? .failed : outcome == .delivered ? .confirmed : incoming.status, existing.payload)
    }

    /// The history entry of a Jetton request replaces the send record, which holds the transfer's intent; the
    /// delivery reference takes it over.
    private static func carryingJettonIntent(
        _ incoming: (status: BlockchainTransactionStatus, payload: Data?),
        from existing: Data?
    ) -> (status: BlockchainTransactionStatus, payload: Data?) {
        guard var fresh = deliveryReference(incoming.payload), fresh.isJettonRequest == true, fresh.jetton == nil,
              let existing
        else {
            return incoming
        }

        let pending: TonPendingSend? = try? existing.decoded()
        let reference: TonDeliveryReference? = try? existing.decoded()

        guard let intent = pending?.jetton ?? reference?.jetton else {
            return incoming
        }

        fresh.jetton = intent
        return (incoming.status, (try? fresh.encoded()) ?? incoming.payload)
    }

    /// Rebuilds the transfer of an entry that has no stored intent (restored from history) from its one token effect
    /// (`query:<id>[|local]`). Without the sender's Jetton wallet; unclear with several candidates.
    private static func attachJetton(of model: WalletTransactionModel, to reference: inout TonDeliveryReference) {
        guard reference.jetton == nil else {
            return
        }

        let candidates = model.effects.filter {
            $0.kind == BlockchainTransactionEffect.Kind.tokenTransfer.rawValue
                && $0.rawPayload.flatMap { String(data: $0, encoding: .utf8) }?.hasPrefix("query:") == true
        }

        guard candidates.count == 1, let effect = candidates.first,
              let text = effect.rawPayload.flatMap({ String(data: $0, encoding: .utf8) }),
              let queryId = UInt64(text.dropFirst("query:".count).prefix { $0 != "|" }),
              let master = effect.assetIdentifier, let amount = effect.amount, let recipient = effect.recipient
        else {
            return
        }

        reference.jetton = TonJettonTransfer(
            amount: amount,
            master: master,
            queryId: queryId,
            recipient: recipient,
            senderWallet: ""
        )
    }

    private static func deliveryReference(_ payload: Data?) -> TonDeliveryReference? {
        guard let payload else {
            return nil
        }

        return try? payload.decoded()
    }

    /// The TON Jetton scan's stored progress; both are `nil` for an account not scanned yet.
    func fetchJettonSyncProgress(accountId: PersistentIdentifier) throws -> (backfill: Data?, forward: Data?) {
        let predicate = #Predicate<AccountModel> { $0.persistentModelID == accountId }
        let state = try modelContext.fetch(FetchDescriptor(predicate: predicate)).first?.transactionSyncState
        return (state?.jettonBackfillCursor, state?.jettonForwardState)
    }

    /// Stores the Jetton scan's progress together with the entries it read, touching no other sync field so
    /// the owner wallet's own scan keeps its progress.
    func saveJettonSync(
        _ transactions: [BlockchainTransaction],
        for account: Account,
        backfill: Data?,
        forward: Data?
    ) throws {
        try saveTransactions(transactions, for: account)

        guard let accountId = account.id else {
            throw ReefrError.invalidData
        }

        let predicate = #Predicate<AccountModel> { $0.persistentModelID == accountId }

        guard let accountModel = try modelContext.fetch(FetchDescriptor(predicate: predicate)).first else {
            throw ReefrError.notFound
        }

        let model: WalletTransactionSyncStateModel

        if let existing = accountModel.transactionSyncState {
            model = existing
        } else {
            model = WalletTransactionSyncStateModel(
                account: accountModel,
                state: WalletTransactionSyncState(accountId: accountId)
            )

            accountModel.transactionSyncState = model
            modelContext.insert(model)
        }

        model.jettonBackfillCursor = backfill
        model.jettonForwardState = forward
        try modelContext.save()
    }
}

extension DatabaseService {
    /// A send's local effect carries its payload plus a `|local` suffix; the history effect with the same payload
    /// replaces it, so one payment never shows twice.
    static func dropReplacedLocalEffects(
        of model: WalletTransactionModel,
        by incoming: [WalletTransactionEffect],
        in context: ModelContext
    ) {
        let stable = Set(incoming.map(\.stableId))
        let keys = Set(incoming.compactMap { $0.rawPayload.flatMap { String(data: $0, encoding: .utf8) } })

        for existing in model.effects where !stable.contains(existing.stableId) {
            guard let text = existing.rawPayload.flatMap({ String(data: $0, encoding: .utf8) }),
                  text.hasSuffix("|local"),
                  keys.contains(String(text.dropLast("|local".count)))
            else {
                continue
            }

            context.delete(existing)
        }
    }

    /// An effect's id under a new parent id. Keeps the suffix (index, kind, key), so effects that differ only by
    /// key stay apart.
    static func reparentedEffectId(_ effect: WalletTransactionEffectModel, from old: String, to new: String) -> String {
        effect.stableId.hasPrefix(old + "|")
            ? new + effect.stableId.dropFirst(old.count)
            : "\(new)|\(effect.effectIndex)|\(effect.kind)"
    }
}
