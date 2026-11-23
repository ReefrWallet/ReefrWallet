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
    static let kind = DefiPluginKind.uniswapV3
    /// History log queries per run.
    static let historyBudget = 20
    /// The revert message of `ownerOf` for a burned or never-minted token (OpenZeppelin 3.4).
    static let nonexistentTokenReason = "ERC721: owner query for nonexistent token"
    /// NFT scans older than this are refreshed before the next run reads them.
    static let nftScanMaxAge: TimeInterval = 5 * 60
    /// The confirmation depth used as the safe block where `finalized` isn't supported.
    static let safeDepth: UInt64 = 64

    let account: Account

    private let databaseService: DatabaseService
    private let deployments: [UInt64: UniswapV3Deployment]
    private let readerFactory: @Sendable (Account) throws -> any DefiEVMReader
    private let requestNFTRefresh: @Sendable (Account) -> Void
    private let runs = DefiRunCounter()
    private let tokenSource: any UniswapV3TokenSource

    init(account: Account) {
        self.init(account: account, databaseService: DI.injectOrFail(DatabaseService.self))
    }

    init(
        account: Account,
        databaseService: DatabaseService,
        deployments: [UInt64: UniswapV3Deployment] = UniswapV3Deployment.all,
        readerFactory: (@Sendable (Account) throws -> any DefiEVMReader)? = nil,
        requestNFTRefresh: (@Sendable (Account) -> Void)? = nil,
        tokenSource: any UniswapV3TokenSource = LiveUniswapV3TokenSource()
    ) {
        self.account = account
        self.databaseService = databaseService
        self.deployments = deployments
        self.readerFactory = readerFactory ?? { account in
            try IndexedLogsDefiEVMReader.live(account: account)
        }

        self.requestNFTRefresh = requestNFTRefresh ?? { account in
            DI.injectOrFail(NFTService.self).enqueueRefresh(account)
        }

        self.tokenSource = tokenSource
    }

    static func isSupported(_ blockchain: Blockchain) -> Bool {
        UniswapV3Deployment.deployment(for: blockchain) != nil
    }

    // MARK: - Refresh

    /// Keeps the NFT scan fresh, then values the account's position NFTs once a scan has completed.
    func refresh() async throws {
        let scanStates = try await databaseService.fetchNFTScanStates(account: account)

        if isScanStale(scanStates, now: .now) {
            requestNFTRefresh(account)
        }

        guard scanStates.values.contains(where: { $0.isSnapshotSource && $0.lastCompleteScanAt != nil }) else {
            return
        }

        let outcomes = try await outcomes(
            nfts: databaseService.fetchNFTs(account: account),
            mints: databaseService.fetchNFTMints(account: account),
            previous: databaseService.fetchDefiPositions(account: account, kind: Self.kind),
            budget: DefiRequestBudget(Self.historyBudget),
            rotation: runs.next()
        )

        try await databaseService.saveDefiOutcomes(account: account, kind: Self.kind, outcomes)
    }

    /// Whether the scan this account's positions come from is missing or old. Override
    /// accounts follow their node's own scan, so a fallback to an indexer still retries it.
    func isScanStale(_ scanStates: [NFTSourceId: NFTScanState], now: Date) -> Bool {
        let source = account.rpcURLOverride != nil
            ? NFTSourceId.node
            : scanStates.first(where: \.value.isSnapshotSource)?.key ?? .blockscout

        guard let scannedAt = scanStates[source]?.lastCompleteScanAt else {
            return true
        }

        return now.timeIntervalSince(scannedAt) >= Self.nftScanMaxAge
    }

    /// One outcome per stored or owned position: valued, removed or failed.
    /// - Parameter rotation: Where the run starts handing out `budget`.
    func outcomes(
        nfts: [NFT],
        mints: [String: NFTMint],
        previous: [DefiPosition],
        budget: DefiRequestBudget,
        rotation: Int
    ) async throws -> [DefiPositionOutcome] {
        guard case let .evm(chain) = account.blockchain, let deployment = deployments[chain.chainId] else {
            return []
        }

        let reader = try readerFactory(account)

        guard let pinned = try await reader.block(.latest) else {
            throw BlockchainClientError.decodingFailed(reason: "no latest block")
        }

        let safe = try await safeBlock(reader: reader, pinned: pinned)
        let previous = Self.payloads(previous)
        let candidates = positionNFTs(nfts, deployment: deployment, chainId: chain.chainId)
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
            budget: budget,
            chunks: ChunkSizer(reader.preferredLogRange),
            deployment: deployment,
            pinned: pinned,
            reader: reader,
            safe: safe
        )

        for position in Self.rotated(live, by: rotation) {
            outcomes.append(
                try await valuate(position, tokens: tokens, mints: mints, scanner: scanner, previous: previous)
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
        mints: [String: NFTMint],
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
                ledgerMint: mints[position.candidate.nftKey],
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

    func positionNFTs(_ nfts: [NFT], deployment: UniswapV3Deployment, chainId: UInt64) -> [Candidate] {
        let manager = deployment.positionManager.string.lowercased()

        return nfts.compactMap { nft in
            guard nft.reference.standard == .erc721,
                  nft.reference.collection.lowercased() == manager,
                  let tokenId = BigUInt(nft.reference.tokenId, radix: 10)
            else {
                return nil
            }

            return Candidate(key: "\(chainId):\(tokenId)", nftKey: nft.id, tokenId: tokenId)
        }
    }

    private static func payloads(_ positions: [DefiPosition]) -> [String: UniswapV3Position] {
        positions.reduce(into: [:]) { result, position in
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
