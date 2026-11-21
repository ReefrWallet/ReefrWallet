//
//  UniswapV3Plugin.swift
//  Reefr Wallet
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation
import WalletKit

/// Uniswap V3 LP positions from the account's position-manager NFTs. See ADR-073.
struct UniswapV3Plugin: DefiPlugin {
    /// The revert message of `ownerOf` for a burned or never-minted token (OpenZeppelin 3.4).
    static let nonexistentTokenReason = "ERC721: owner query for nonexistent token"
    /// The confirmation depth used as the safe block where `finalized` isn't supported.
    static let safeDepth: UInt64 = 64

    let kind = DefiPluginKind.uniswapV3

    private let deployments: [UInt64: UniswapV3Deployment]
    private let readerFactory: @Sendable (Account) throws -> any DefiEVMReader
    private let tokenSource: any UniswapV3TokenSource

    init(
        deployments: [UInt64: UniswapV3Deployment] = UniswapV3Deployment.all,
        readerFactory: (@Sendable (Account) throws -> any DefiEVMReader)? = nil,
        tokenSource: any UniswapV3TokenSource = LiveUniswapV3TokenSource()
    ) {
        self.deployments = deployments
        self.readerFactory = readerFactory ?? { account in
            try IndexedLogsDefiEVMReader.live(account: account)
        }

        self.tokenSource = tokenSource
    }

    // MARK: - Eligibility

    func isCandidate(_ account: Account) -> Bool {
        guard case let .evm(chain) = account.blockchain, deployments[chain.chainId] != nil else {
            return false
        }

        return account.rpcURLOverride != nil || UniswapV3Deployment.verifiedProviderChains.contains(chain.chainId)
    }

    func isEligible(_ account: Account, scanStates: [NFTSourceId: NFTScanState]) -> Bool {
        let snapshot = scanStates.first { $0.value.isSnapshotSource && $0.value.lastCompleteScanAt != nil }?.key

        guard isCandidate(account), case let .evm(chain) = account.blockchain, let snapshot else {
            return false
        }

        let isPublicIndexer = snapshot == .blockscout || snapshot == .etherscan

        if account.rpcURLOverride != nil {
            let isVerified = UniswapV3Deployment.verifiedProviderChains.contains(chain.chainId)
            return snapshot == .node || (isPublicIndexer && isVerified)
        }

        return isPublicIndexer
    }

    func requiredScanSource(_ account: Account, scanStates: [NFTSourceId: NFTScanState]) -> NFTSourceId? {
        guard isCandidate(account) else {
            return nil
        }

        // An override account retries its node on the node scan's own freshness.
        if account.rpcURLOverride != nil {
            return .node
        }

        return scanStates.first(where: \.value.isSnapshotSource)?.key ?? .blockscout
    }

    // MARK: - Fetch

    func fetch(_ context: DefiPluginContext) async throws -> [DefiPositionOutcome] {
        let account = context.account

        guard case let .evm(chain) = account.blockchain, let deployment = deployments[chain.chainId] else {
            return []
        }

        let reader = try readerFactory(account)

        guard let pinned = try await reader.block(.latest) else {
            throw BlockchainClientError.decodingFailed(reason: "no latest block")
        }

        let safe = try await safeBlock(reader: reader, pinned: pinned)
        let previous = previousPositions(context.input)
        let candidates = positionNFTs(context.input, deployment: deployment, chainId: chain.chainId)
        var outcomes = previous.keys
            .filter { key in !candidates.contains { $0.key == key } }
            .map { DefiPositionOutcome.removed(key: $0) }

        let states = try await readStates(
            candidates,
            owner: account.address,
            deployment: deployment,
            reader: reader,
            at: pinned
        )

        let live = Self.classify(candidates, states: states, chainId: chain.chainId, outcomes: &outcomes)
        let tokens = await tokenSource.tokens(Self.tokenAddresses(live), account: account, now: pinned.timestamp)
        let blocks = BlockCache(reader: reader, known: [pinned, safe])
        let scanner = UniswapV3HistoryScanner(
            blocks: blocks,
            budget: context.budget,
            chunks: ChunkSizer(reader.preferredLogRange),
            deployment: deployment,
            pinned: pinned,
            reader: reader,
            safe: safe
        )

        for position in Self.rotated(live, by: context.rotation) {
            outcomes.append(
                try await valuate(position, tokens: tokens, context: context, scanner: scanner, previous: previous)
            )
        }

        // Every read was pinned to this block; a reorg during the run voids them all.
        guard try await reader.block(.number(pinned.number))?.hash == pinned.hash else {
            throw BlockchainClientError.decodingFailed(reason: "block \(pinned.number) reorganized during the run")
        }

        return outcomes
    }
}

// MARK: - Run helpers

extension UniswapV3Plugin {
    /// Live positions to value; removed and unreadable ones go straight to `outcomes`.
    private static func classify(
        _ candidates: [Candidate],
        states: [String: ReadResult],
        chainId: UInt64,
        outcomes: inout [DefiPositionOutcome]
    ) -> [LivePosition] {
        var live: [LivePosition] = []

        for candidate in candidates {
            switch states[candidate.key] {
            case let .live(state):
                live.append(LivePosition(candidate: candidate, chainId: chainId, state: state))

            case .removed:
                outcomes.append(.removed(key: candidate.key))

            case .failed, nil:
                outcomes.append(.failed(key: candidate.key))
            }
        }

        return live
    }

    /// Scans a live position's history and builds its outcome.
    private func valuate(
        _ position: LivePosition,
        tokens: [String: UniswapV3Position.Token],
        context: DefiPluginContext,
        scanner: UniswapV3HistoryScanner,
        previous: [String: UniswapV3Position]
    ) async throws -> DefiPositionOutcome {
        let key = position.candidate.key

        guard let token0 = tokens[position.state.token0.string.lowercased()],
              let token1 = tokens[position.state.token1.string.lowercased()]
        else {
            return .failed(key: key)
        }

        let previousHistory = previous[key]?.history ?? .empty
        let history: UniswapV3HistoryScanner.Result

        do {
            history = try await scanner.scan(
                tokenId: position.candidate.tokenId,
                previous: previousHistory,
                ledgerMint: context.input.mints[position.candidate.nftKey],
                searchFloor: await searchFloor(
                    below: position.candidate.tokenId,
                    previous: previous,
                    blocks: scanner.blocks
                )
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            printWarning("Uniswap V3 #\(position.candidate.tokenId) history: \(error)")
            history = .init(mint: nil, persisted: previousHistory, state: .unavailable, totals: nil)
        }

        return Self.outcome(
            key: key,
            chainId: position.chainId,
            position: position,
            history: history,
            tokens: (token0, token1),
            pinned: scanner.pinned
        )
    }

    private static func tokenAddresses(_ live: [LivePosition]) -> [EthereumAddress] {
        var addresses: [String: EthereumAddress] = [:]

        for position in live {
            addresses[position.state.token0.string.lowercased()] = position.state.token0
            addresses[position.state.token1.string.lowercased()] = position.state.token1
        }

        return Array(addresses.values)
    }

    func positionNFTs(_ input: DefiInput, deployment: UniswapV3Deployment, chainId: UInt64) -> [Candidate] {
        let manager = deployment.positionManager.string.lowercased()

        return input.nfts.compactMap { nft in
            guard nft.reference.standard == .erc721,
                  nft.reference.collection.lowercased() == manager,
                  let tokenId = BigUInt(nft.reference.tokenId, radix: 10)
            else {
                return nil
            }

            return Candidate(key: "\(chainId):\(tokenId)", nftKey: nft.id, tokenId: tokenId)
        }
    }

    private func previousPositions(_ input: DefiInput) -> [String: UniswapV3Position] {
        input.positions.reduce(into: [:]) { result, position in
            guard position.kind == kind else {
                return
            }

            result[position.key] = try? position.payload.decoded() as UniswapV3Position
        }
    }

    private func safeBlock(reader: any DefiEVMReader, pinned: BlockRef) async throws -> BlockRef {
        if let finalized = try await reader.block(.finalized), finalized.number <= pinned.number {
            return finalized
        }

        let number = pinned.number > Self.safeDepth ? pinned.number - Self.safeDepth : 0

        guard let block = try await reader.block(.number(number)) else {
            throw BlockchainClientError.decodingFailed(reason: "no block \(number)")
        }

        return block
    }

    /// The newest still-canonical persisted mint of a lower token id.
    private func searchFloor(
        below tokenId: BigUInt,
        previous: [String: UniswapV3Position],
        blocks: BlockCache
    ) async -> UInt64? {
        let mints = previous.values
            .filter { BigUInt($0.tokenId) ?? 0 < tokenId }
            .compactMap(\.history.mint)
            .sorted { $0.number > $1.number }

        for mint in mints where (try? await blocks.isCanonical(mint)) == true {
            return mint.number
        }

        return nil
    }

    static func rotated<Element>(_ elements: [Element], by rotation: Int) -> [Element] {
        guard !elements.isEmpty else {
            return elements
        }

        let offset = ((rotation % elements.count) + elements.count) % elements.count
        return Array(elements[offset...] + elements[..<offset])
    }
}
