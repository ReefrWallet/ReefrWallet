//
//  UniswapV3HistoryScanner.swift
//  Reefr Wallet
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation
import WalletKit

/// Scans a position's mint, Collect and DecreaseLiquidity logs. Progress is
/// persisted only through the safe block and rechecked by hash every run;
/// the tail above it is rescanned each time. See ADR-073.
struct UniswapV3HistoryScanner: Sendable {
    static let collectTopic = topic("Collect(uint256,address,uint256,uint256)")
    static let decreaseTopic = topic("DecreaseLiquidity(uint256,uint128,uint256,uint256)")
    static let initialChunk: UInt64 = 100_000
    static let minimumChunk: UInt64 = 1_000
    static let transferTopic = topic("Transfer(address,address,uint256)")

    struct Result: Equatable, Sendable {
        /// The mint seen this run, persisted or not.
        let mint: BlockRef?
        /// What may be stored: progress through the safe block only.
        let persisted: UniswapV3Position.History
        let state: UniswapV3Position.HistoryState
        /// Persisted sums plus the tail's, when the scan reached the pinned block.
        let totals: (collected: UniswapV3Position.Amounts, decreased: UniswapV3Position.Amounts)?

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.mint == rhs.mint && lhs.persisted == rhs.persisted && lhs.state == rhs.state
                && lhs.totals?.collected == rhs.totals?.collected && lhs.totals?.decreased == rhs.totals?.decreased
        }
    }

    let blocks: BlockCache
    let budget: DefiRequestBudget
    let chunks: ChunkSizer
    let deployment: UniswapV3Deployment
    let pinned: BlockRef
    let reader: any DefiEVMReader
    let safe: BlockRef

    /// - Parameters:
    ///   - ledgerMint: The NFT ledger's mint, if the account received the token at mint.
    ///   - searchFloor: A verified mint of a lower token id; ids are sequential.
    func scan(
        tokenId: BigUInt,
        previous: UniswapV3Position.History,
        ledgerMint: DefiMintEvidence?,
        searchFloor: UInt64?
    ) async throws -> Result {
        var history = try await verified(previous)
        let mint: BlockRef?

        if let persisted = history.mint {
            mint = persisted
        } else if let found = try await ledgerMintBlock(ledgerMint) {
            mint = found
        } else {
            switch try await searchMint(tokenId: tokenId, history: &history, floor: searchFloor) {
            case let .found(block):
                mint = block
            case .incomplete:
                return Result(mint: nil, persisted: history, state: .loading, totals: nil)
            case .notFound:
                return Result(mint: nil, persisted: history, state: .unavailable, totals: nil)
            }
        }

        guard let mint else {
            return Result(mint: nil, persisted: history, state: .unavailable, totals: nil)
        }

        if mint.number <= safe.number {
            history.mint = mint
            history.mintSearchCursor = nil
        }

        return try await scanAmounts(tokenId: tokenId, mint: mint, history: history)
    }

    // MARK: - Mint

    private enum MintSearch {
        case found(BlockRef)
        case incomplete
        case notFound
    }

    private func ledgerMintBlock(_ evidence: DefiMintEvidence?) async throws -> BlockRef? {
        guard let evidence, let block = try await blocks.block(evidence.blockNumber) else {
            return nil
        }

        // An indexer's block hash from before a reorg disqualifies its evidence.
        if let hash = evidence.blockHash, hash.lowercased() != block.hash {
            return nil
        }

        return block
    }

    private func searchMint(
        tokenId: BigUInt,
        history: inout UniswapV3Position.History,
        floor: UInt64?
    ) async throws -> MintSearch {
        var from = history.mintSearchCursor.map { $0.number + 1 } ?? max(floor ?? 0, deployment.deploymentBlock)
        let topics: [[String]?] = [[Self.transferTopic], [Self.word(0)], nil, [Self.word(tokenId)]]

        while from <= pinned.number {
            guard await budget.spend() else {
                return .incomplete
            }

            let to = min(from + (await chunks.size) - 1, pinned.number)

            guard let logs = try await logs(topics: topics, from: from, to: to) else {
                continue
            }

            if let log = logs.min(by: { $0.blockNumber < $1.blockNumber }) {
                guard let block = try await blocks.block(log.blockNumber), block.hash == log.blockHash else {
                    return .incomplete
                }

                return .found(block)
            }

            if to <= safe.number {
                history.mintSearchCursor = try await blocks.block(to)
            }

            from = to + 1
        }

        return .notFound
    }

    // MARK: - Amounts

    private func scanAmounts(
        tokenId: BigUInt,
        mint: BlockRef,
        history: UniswapV3Position.History
    ) async throws -> Result {
        var history = history
        let topics: [[String]?] = [[Self.collectTopic, Self.decreaseTopic], [Self.word(tokenId)]]
        var from = history.checkpoint.map { $0.number + 1 } ?? mint.number
        var tailCollected = UniswapV3Position.Amounts.zero
        var tailDecreased = UniswapV3Position.Amounts.zero
        let isPersistable = history.mint != nil

        while from <= pinned.number {
            guard await budget.spend() else {
                return Result(mint: mint, persisted: history, state: .loading, totals: nil)
            }

            // Ranges never straddle the safe block, so a chunk is either persisted or tail.
            let limit = isPersistable && from <= safe.number ? safe.number : pinned.number
            let to = min(from + (await chunks.size) - 1, limit)

            guard let logs = try await logs(topics: topics, from: from, to: to) else {
                continue
            }

            let (collected, decreased) = Self.sums(logs)

            if isPersistable && to <= safe.number {
                guard let checkpoint = try await blocks.block(to) else {
                    return Result(mint: mint, persisted: history, state: .loading, totals: nil)
                }

                history.collected += collected
                history.decreased += decreased
                history.checkpoint = checkpoint
            } else {
                tailCollected += collected
                tailDecreased += decreased
            }

            from = to + 1
        }

        return Result(
            mint: mint,
            persisted: history,
            state: .complete,
            totals: (history.collected + tailCollected, history.decreased + tailDecreased)
        )
    }

    // MARK: - Helpers

    /// Drops persisted progress whose block left the canonical chain.
    private func verified(_ history: UniswapV3Position.History) async throws -> UniswapV3Position.History {
        var history = history

        if let mint = history.mint, try await !blocks.isCanonical(mint) {
            return .empty
        }

        if let cursor = history.mintSearchCursor, try await !blocks.isCanonical(cursor) {
            history.mintSearchCursor = nil
        }

        if let checkpoint = history.checkpoint, try await !blocks.isCanonical(checkpoint) {
            history.checkpoint = nil
            history.collected = .zero
            history.decreased = .zero
        }

        return history
    }

    /// Fetches logs, halving the chunk on a provider error; `nil` means retry the range.
    private func logs(topics: [[String]?], from: UInt64, to: UInt64) async throws -> [EVMLog]? {
        do {
            return try await reader.logs(address: deployment.positionManager, topics: topics, from: from, to: to)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard await chunks.shrink() else {
                throw error
            }

            return nil
        }
    }

    static func sums(_ logs: [EVMLog]) -> (UniswapV3Position.Amounts, UniswapV3Position.Amounts) {
        var collected = UniswapV3Position.Amounts.zero
        var decreased = UniswapV3Position.Amounts.zero

        for log in logs {
            let words = EthereumABI.words(log.data)

            guard words.count >= 3 else {
                continue
            }

            let amounts = UniswapV3Position.Amounts(
                EthereumABI.decodeUInt256(words[1]),
                EthereumABI.decodeUInt256(words[2])
            )

            switch log.topics.first {
            case collectTopic: collected += amounts
            case decreaseTopic: decreased += amounts
            default: continue
            }
        }

        return (collected, decreased)
    }

    static func topic(_ signature: String) -> String {
        EthereumABI.keccak256(Data(signature.utf8)).hexEncoded
    }

    static func word(_ value: BigUInt) -> String {
        EthereumABI.encodeCall(selector: Data(), parameters: [.uint256(value)]).hexEncoded
    }
}

// MARK: - Run-scoped helpers

/// Block headers by number for one run, with canonical-hash checks.
actor BlockCache {
    private var blocks: [UInt64: BlockRef?] = [:]
    private let reader: any DefiEVMReader

    init(reader: any DefiEVMReader, known: [BlockRef] = []) {
        self.reader = reader

        for block in known {
            blocks[block.number] = block
        }
    }

    func block(_ number: UInt64) async throws -> BlockRef? {
        if let cached = blocks[number] {
            return cached
        }

        let block = try await reader.block(.number(number))
        blocks[number] = block
        return block
    }

    func isCanonical(_ ref: BlockRef) async throws -> Bool {
        try await block(ref.number)?.hash == ref.hash
    }
}

/// The `eth_getLogs` range for one run, halved when a provider rejects it.
actor ChunkSizer {
    private(set) var size: UInt64

    init(_ size: UInt64 = UniswapV3HistoryScanner.initialChunk) {
        self.size = size
    }

    /// Halves the range; `false` when it's already at the minimum.
    func shrink() -> Bool {
        guard size > UniswapV3HistoryScanner.minimumChunk else {
            return false
        }

        size = max(size / 2, UniswapV3HistoryScanner.minimumChunk)
        return true
    }
}
