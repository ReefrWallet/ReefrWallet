//
//  TransactionConfirmationService.swift
//  Reefr Wallet
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation
import WalletKit

/// What a chain reports about a broadcast transaction.
enum TransactionConfirmationStatus: Equatable, Sendable {
    /// Failed on chain (reverted, or an execution error).
    case failed
    /// The node doesn't know it. Never proof that it won't land.
    case notFound
    /// Known but not final yet.
    case pending
    /// Succeeded at `position`: EVM block, Solana slot, Aptos version, Cardano
    /// slot, or `nil` where the chain has none to compare (Sui).
    case success(position: UInt64?)
}

/// Reads and waits for a transaction's outcome on the NFT chains.
struct TransactionConfirmationService: Sendable {
    static let pollInterval: Duration = .seconds(3)
    static let timeout: Duration = .seconds(180)

    var clientProvider = BlockchainClientProvider()

    func status(hash: String, account: Account) async throws -> TransactionConfirmationStatus {
        let client = try clientProvider.makeClient(blockchain: account.blockchain, rpcURL: account.rpcURLOverride)

        switch client {
        case let client as EthereumRPCClient:
            return try await ethereumStatus(hash: hash, client: client)
        case let client as SolanaRPCClient:
            let confirmation = try await client.signatureConfirmation(hash, searchHistory: true)
            return switch confirmation.status {
            case .confirmed: .success(position: confirmation.slot)
            case .failed: .failed
            case .notFound: .notFound
            case .processed: .pending
            }

        case let client as SuiGRPCClient:
            return switch try await client.transactionStatus(digest: hash) {
            case let .finalized(failure): failure == nil ? .success(position: nil) : .failed
            case .notFound: .notFound
            }

        case let client as AptosClient:
            guard let status = try await client.transaction(byHash: hash) else {
                return .notFound
            }

            if status.isPending {
                return .pending
            }

            return status.success == true ? .success(position: status.version) : .failed
        case let client as CardanoClient:
            return try await client.transactionConfirmation(hash).map { .success(position: $0.slot) } ?? .notFound
        default:
            throw ReefrError.invalidData
        }
    }

    /// Polls until success, failure or timeout.
    ///
    /// - Returns: The success position.
    /// - Throws: ``TransactionConfirmationError``.
    func waitForSuccess(hash: String, account: Account) async throws -> UInt64? {
        let deadline = ContinuousClock.now.advanced(by: Self.timeout)

        while ContinuousClock.now < deadline {
            switch try? await status(hash: hash, account: account) {
            case let .success(position):
                return position
            case .failed:
                throw TransactionConfirmationError.failed(hash)
            default:
                try await Task.sleep(for: Self.pollInterval)
            }
        }

        throw TransactionConfirmationError.timedOut(hash)
    }

    private func ethereumStatus(hash: String, client: EthereumRPCClient) async throws -> TransactionConfirmationStatus {
        let params = try JSONValue.array([.string(hash)]).encoded()
        let receipt = try JSONValue(data: await client.request(method: "eth_getTransactionReceipt", params: params))

        guard let status = receipt["status"]?.stringValue else {
            return .notFound
        }

        guard status == "0x1" else {
            return .failed
        }

        let block = receipt["blockNumber"]?.stringValue.flatMap { UInt64($0.dropFirst(2), radix: 16) }
        return .success(position: block)
    }
}

enum TransactionConfirmationError: LocalizedError, Equatable {
    case failed(String)
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case .failed:
            String(localized: .nftTransferFailed)
        case .timedOut:
            String(localized: .nftTransferUnconfirmed)
        }
    }
}
