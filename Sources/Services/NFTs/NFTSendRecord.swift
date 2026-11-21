//
//  NFTSendRecord.swift
//  Reefr Wallet
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation
import WalletKit

/// Builds the ``NFTPendingSend`` stored when an NFT send is broadcast: what
/// later proves it landed, or that it can't (ADR-072).
enum NFTSendRecord {
    /// Aptos builders expire transactions 600 s after the node's ledger time,
    /// which trails the wall clock; a later bound only delays evidence.
    static let aptosExpiryMargin: TimeInterval = 660

    /// The Sui object's `id|version|digest` before the send, read from the node.
    static func suiObjectReference(nft: NFTReference, account: Account) async throws -> String? {
        guard nft.standard == .suiObject else {
            return nil
        }

        let client = try DI.injectOrFail(BlockchainClientProvider.self).suiClient(for: account)
        let object = try await client.object(id: nft.tokenId, readMask: ["object_id", "version", "digest"])
        return [object.objectID, String(object.version), object.digest].joined(separator: "|")
    }

    static func make(
        nft: NFT,
        quantity: BigUInt,
        transaction: Data,
        suiObjectReference: String?,
        account: Account
    ) async throws -> NFTPendingSend {
        var send = NFTPendingSend(
            broadcastAt: .now,
            confirmedAt: nil,
            confirmedPosition: nil,
            consumedOutpoints: [],
            expiry: nil,
            expirySlot: nil,
            nftKey: nft.id,
            nonce: nil,
            objectVersion: nil,
            quantity: quantity,
            quantityBefore: nft.quantity,
            state: .broadcast,
            txHash: ""
        )

        switch account.blockchain {
        case .aptos:
            send.expiry = UInt64(Date.now.addingTimeInterval(aptosExpiryMargin).timeIntervalSince1970)
        case .cardano:
            let unsigned = try JSONDecoder().decode(CardanoUnsignedTransaction.self, from: transaction)
            send.consumedOutpoints = unsigned.inputs.map { "\($0.txHash.hexString)#\($0.outputIndex)" }
            send.expiry = unsigned.ttl
        case .evm:
            let client = try DI.injectOrFail(BlockchainClientProvider.self).ethereumClient(for: account)
            send.nonce = try await client.nonce(of: EthereumAddress(string: account.address))
        case .solana:
            let envelope = try JSONDecoder().decode(SolanaUnsignedTransaction.self, from: transaction)
            send.expiry = envelope.lastValidBlockHeight
        case .sui:
            send.consumedOutpoints = suiObjectReference.map { [$0] } ?? []
            send.objectVersion = suiObjectReference
                .flatMap { $0.split(separator: "|").dropFirst().first }
                .flatMap { UInt64($0) }
        case .bitcoin, .ton, .tron:
            break
        }

        return send
    }

    /// Whether `recipient` is one of `account`'s own addresses.
    static func isOwnAddress(_ recipient: String, account: Account) async throws -> Bool {
        let recipient = recipient.lowercased()

        guard case .cardano = account.blockchain else {
            return recipient == account.address.lowercased()
        }

        guard let accountId = account.id else {
            return false
        }

        return try await DI.injectOrFail(DatabaseService.self)
            .fetchReceiveAddresses(accountId: accountId)
            .contains { $0.address.lowercased() == recipient }
    }
}

extension NFTPendingSend {
    func withHash(_ hash: String) -> NFTPendingSend {
        var copy = self
        copy.txHash = hash
        return copy
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
