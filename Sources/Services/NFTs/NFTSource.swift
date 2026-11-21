//
//  NFTSource.swift
//  Reefr Wallet
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation
import WalletKit

/// An NFT ownership source. See ADR-072.
enum NFTSourceId: String, Sendable {
    case blockscout
    case etherscan
    case node
    case walletKit

    var displayName: String {
        switch self {
        case .blockscout: "Blockscout"
        case .etherscan: "Etherscan"
        case .node: "the node"
        case .walletKit: "the network"
        }
    }

    var isLedger: Bool {
        self != .walletKit
    }
}

/// What one complete scan returned.
enum NFTScanResult: Sendable {
    /// EVM: transfer events from `fromBlock` up, plus metadata the source had.
    case ledger(NFTLedgerScan)
    /// Other chains: the current holdings and the position they were read at.
    case listing(holdings: [OwnedNFT], position: NFTSnapshotPosition?)
}

struct NFTLedgerScan: Sendable {
    let events: [NFTTransferEvent]
    let fromBlock: UInt64
    /// Metadata by ``NFTLedger/assetKey(_:)``.
    let metadata: [String: OwnedNFT]
    /// The newest block the scan covered.
    let scannedBlock: UInt64
}

/// Where an account's NFT scan starts and what it must cover.
struct NFTScanRequest: Sendable {
    /// Solana: reads must be served at or after this slot.
    let minContextSlot: UInt64?
    /// Ledger sources: the newest block of this source's previous complete scan.
    let scannedBlock: UInt64?

    static let reorgOverlap: UInt64 = 32

    var overlapStart: UInt64 {
        scannedBlock.map { $0 > Self.reorgOverlap ? $0 - Self.reorgOverlap : 0 } ?? 0
    }
}

protocol NFTSource: Sendable {
    var id: NFTSourceId { get }

    func supports(_ blockchain: Blockchain) -> Bool

    /// Scans `account` completely, or throws: a partial scan is never returned.
    func scan(account: Account, request: NFTScanRequest) async throws -> NFTScanResult
}
