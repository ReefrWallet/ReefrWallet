//
//  NFTReconciler.swift
//  Reefr Wallet
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation
import WalletKit

/// Applies pending sends to a complete ownership snapshot. A confirmed send
/// is cleared only by evidence from the snapshot itself; until then its
/// quantity is subtracted. See ADR-072.
enum NFTReconciler {
    /// What a snapshot proves, taken from the same response(s) as its holdings.
    enum Evidence: Sendable {
        /// EVM ledgers: `txHash|assetKey` of every stored event.
        case ledger(transferKeys: Set<String>)
        case listing(NFTSnapshotPosition?)
    }

    struct Result: Equatable {
        let holdings: [OwnedNFT]
        /// Confirmed sends the snapshot reflects, to delete.
        let reflected: Set<String>
    }

    static let waitingThreshold: TimeInterval = 3600

    static func apply(
        holdings: [OwnedNFT],
        evidence: Evidence,
        pending: [NFTPendingSend],
        nftKey: (NFTReference) -> String
    ) -> Result {
        var byKey = Dictionary(holdings.map { (nftKey($0.reference), $0) }) { first, _ in first }
        var reflected: Set<String> = []

        for send in pending where send.state == .confirmed {
            let holding = byKey[send.nftKey]

            if isReflected(send, holding: holding, evidence: evidence) {
                reflected.insert(send.txHash)
                continue
            }

            guard let holding else {
                continue
            }

            if holding.quantity > send.quantity {
                byKey[send.nftKey] = holding.with(quantity: holding.quantity - send.quantity)
            } else {
                byKey[send.nftKey] = nil
            }
        }

        let ordered = holdings.compactMap { byKey[nftKey($0.reference)] }
        return Result(holdings: ordered, reflected: reflected)
    }

    static func isReflected(_ send: NFTPendingSend, holding: OwnedNFT?, evidence: Evidence) -> Bool {
        switch evidence {
        case let .ledger(keys):
            let assetKey = send.nftKey.split(separator: "|", maxSplits: 1).last.map(String.init) ?? ""
            return keys.contains(send.txHash.lowercased() + "|" + assetKey)
        case let .listing(position):
            switch position {
            case let .aptos(version, _):
                return send.confirmedPosition.map { version >= $0 } ?? false
            case let .cardano(outpoints):
                return !send.consumedOutpoints.isEmpty && outpoints.isDisjoint(with: send.consumedOutpoints)
            case let .solana(slot):
                return send.confirmedPosition.map { slot >= $0 } ?? false
            case .sui:
                guard let holding else {
                    return true
                }

                return send.objectVersion.map { (holding.version ?? 0) > $0 } ?? false
            case nil:
                return false
            }
        }
    }

    /// The send state a card shows for `nftKey`.
    static func sendState(
        for nftKey: String,
        pending: [NFTPendingSend],
        source: NFTSourceId,
        now: Date = .now
    ) -> NFTSendState? {
        let sends = pending.filter { $0.nftKey == nftKey }

        if sends.contains(where: { $0.state == .broadcast }) {
            return .unconfirmed
        }

        if sends.contains(where: { ($0.confirmedAt ?? now).distance(to: now) > waitingThreshold }) {
            return .waitingForIndex(source: source.displayName)
        }

        return nil
    }
}

extension OwnedNFT {
    func with(quantity: BigUInt) -> OwnedNFT {
        OwnedNFT(
            collectionName: collectionName,
            imageURI: imageURI,
            metadataURI: metadataURI,
            name: name,
            objectType: objectType,
            quantity: quantity,
            reference: reference,
            version: version
        )
    }
}
