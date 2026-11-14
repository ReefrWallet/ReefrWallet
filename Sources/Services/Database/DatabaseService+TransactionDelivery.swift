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
        let status = BlockchainTransactionStatus.confirmed.rawValue
        let predicate = #Predicate<WalletTransactionModel> {
            $0.account.persistentModelID == accountId && $0.status == status && $0.rawPayload != nil
        }

        return try modelContext.fetch(FetchDescriptor(predicate: predicate))
            .sorted { ($0.timestamp ?? .distantPast) > ($1.timestamp ?? .distantPast) }
            .compactMap { model -> (stableId: String, reference: TonDeliveryReference)? in
                guard let reference = Self.deliveryReference(model.rawPayload), reference.outcome == nil
                else {
                    return nil
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

        if outcome == .failed {
            model.status = BlockchainTransactionStatus.failed.rawValue
        }

        try modelContext.save()
    }

    /// The status and payload to store when a history import meets `existing`: a recorded recipient outcome
    /// outlives the sender-side entry being re-imported as plain `confirmed`.
    static func preservingDelivery(
        incoming: (status: BlockchainTransactionStatus, payload: Data?),
        existing: (status: String, payload: Data?)
    ) -> (status: BlockchainTransactionStatus, payload: Data?) {
        guard let kept = deliveryReference(existing.payload),
              let outcome = kept.outcome,
              let fresh = deliveryReference(incoming.payload),
              fresh.outMessageHash == kept.outMessageHash
        else {
            return incoming
        }

        return (outcome == .failed ? .failed : incoming.status, existing.payload)
    }

    private static func deliveryReference(_ payload: Data?) -> TonDeliveryReference? {
        guard let payload else {
            return nil
        }

        return try? payload.decoded()
    }
}
