//
//  WalletKitNFTSource.swift
//  Reefr Wallet
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation
import WalletKit

/// Lists Solana, Sui, Aptos and Cardano NFTs through WalletKit's `NFTListing`,
/// following cursors until the listing is complete.
struct WalletKitNFTSource: NFTSource {
    private static let maxPages = 100

    private let clientProvider: BlockchainClientProvider

    let id = NFTSourceId.walletKit

    init(clientProvider: BlockchainClientProvider = BlockchainClientProvider()) {
        self.clientProvider = clientProvider
    }

    func supports(_ blockchain: Blockchain) -> Bool {
        switch blockchain {
        case .aptos, .cardano, .solana, .sui:
            true
        case .bitcoin, .evm, .ton, .tron:
            false
        }
    }

    func scan(account: Account, request: NFTScanRequest) async throws -> NFTScanResult {
        let client = try clientProvider.makeClient(blockchain: account.blockchain, rpcURL: account.rpcURLOverride)

        guard let listing = client as? any NFTListing else {
            throw URLError(.unsupportedURL)
        }

        var holdings: [OwnedNFT] = []
        var positions: [NFTSnapshotPosition] = []
        var cursor: String?

        for _ in 0..<Self.maxPages {
            let page = try await listing.ownedNFTs(
                account.address,
                cursor: cursor,
                minContextSlot: request.minContextSlot
            )

            holdings += page.items
            page.position.map { positions.append($0) }
            cursor = page.cursor

            if cursor == nil {
                return .listing(holdings: holdings, position: Self.combined(positions))
            }
        }

        throw NFTSourceError.tooManyPages
    }

    /// The position a multi-page listing proves: the weakest of its pages.
    static func combined(_ positions: [NFTSnapshotPosition]) -> NFTSnapshotPosition? {
        guard let first = positions.first else {
            return nil
        }

        return positions.dropFirst().reduce(first) { result, next in
            switch (result, next) {
            case let (.aptos(lhs, lhsTime), .aptos(rhs, rhsTime)):
                .aptos(processorVersion: min(lhs, rhs), processorTimestamp: lhs <= rhs ? lhsTime : rhsTime)
            case let (.solana(lhs), .solana(rhs)):
                .solana(slot: min(lhs, rhs))
            case let (.sui(lhs, lhsEpoch), .sui(rhs, rhsEpoch)):
                .sui(
                    checkpoint: [lhs, rhs].compactMap(\.self).min(),
                    epoch: [lhsEpoch, rhsEpoch].compactMap(\.self).min()
                )

            case let (.cardano(lhs), .cardano(rhs)):
                .cardano(outpoints: lhs.union(rhs))
            default:
                result
            }
        }
    }
}

enum NFTSourceError: LocalizedError {
    case noSource
    case tooManyPages

    var errorDescription: String? {
        switch self {
        case .noSource:
            String(localized: .nftsNoSource)
        case .tooManyPages:
            "The NFT listing has too many pages"
        }
    }
}
