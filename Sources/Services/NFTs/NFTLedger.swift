//
//  NFTLedger.swift
//  Reefr Wallet
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation
import WalletKit

/// Recomputes EVM holdings from a ledger of transfer events.
enum NFTLedger {
    /// `standard|collection|tokenId`, collection lowercased.
    static func assetKey(_ reference: NFTReference) -> String {
        assetKey(standard: reference.standard, collection: reference.collection, tokenId: reference.tokenId)
    }

    static func assetKey(standard: NFTStandard, collection: String, tokenId: String) -> String {
        [standard.rawValue, collection.lowercased(), tokenId].joined(separator: "|")
    }

    /// `owner`'s holdings: an ERC-721 belongs to the recipient of its latest
    /// transfer; an ERC-1155 quantity is incoming minus outgoing, dropped at
    /// zero or below.
    static func holdings(events: [NFTTransferEvent], owner: String) -> [NFTReference: BigUInt] {
        let owner = owner.lowercased()
        var latest: [String: NFTTransferEvent] = [:]
        var incoming: [String: BigUInt] = [:]
        var outgoing: [String: BigUInt] = [:]
        var references: [String: NFTReference] = [:]

        for event in events.sorted(by: NFTTransferEvent.ledgerOrder) {
            let reference = NFTReference(
                collection: event.contract.lowercased(),
                isTransferable: true,
                standard: event.standard,
                tokenId: event.tokenId
            )

            let key = assetKey(reference)
            references[key] = reference

            switch event.standard {
            case .erc1155:
                if event.to.lowercased() == owner {
                    incoming[key, default: 0] += event.amount
                }

                if event.from.lowercased() == owner {
                    outgoing[key, default: 0] += event.amount
                }

            default:
                latest[key] = event
            }
        }

        var result: [NFTReference: BigUInt] = [:]

        for (key, event) in latest where event.to.lowercased() == owner {
            references[key].map { result[$0] = 1 }
        }

        for (key, amount) in incoming where amount > outgoing[key, default: 0] {
            references[key].map { result[$0] = amount - outgoing[key, default: 0] }
        }

        return result
    }

    /// `txHash|assetKey` of every event: what a pending send is matched against.
    static func transferKeys(_ events: [NFTTransferEvent]) -> Set<String> {
        Set(events.map {
            $0.txHash.lowercased() + "|" + assetKey(standard: $0.standard, collection: $0.contract, tokenId: $0.tokenId)
        })
    }
}
