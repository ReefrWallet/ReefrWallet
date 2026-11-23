//
//  UniswapV3Plugin+Reading.swift
//  Reefr Wallet
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation
import WalletKit

// MARK: - Reading

extension UniswapV3Plugin {
    struct Candidate: Sendable {
        /// `chainId:tokenId`, the record key.
        let key: String
        let nftKey: String
        let tokenId: BigUInt
    }

    struct State: Sendable {
        let feeGrowthInsideLast: UniswapV3Math.FeeGrowth
        let fee: UInt32
        let liquidity: BigUInt
        let pool: PoolState
        let tickLower: Int
        let tickUpper: Int
        let tickOutsideLower: UniswapV3Math.FeeGrowth
        let tickOutsideUpper: UniswapV3Math.FeeGrowth
        let token0: EthereumAddress
        let token1: EthereumAddress
        let tokensOwed: UniswapV3Position.Amounts

        init(raw: RawPosition, pool: PoolState, lower: UniswapV3Math.FeeGrowth, upper: UniswapV3Math.FeeGrowth) {
            feeGrowthInsideLast = raw.feeGrowthInsideLast
            fee = raw.fee
            liquidity = raw.liquidity
            self.pool = pool
            tickLower = raw.tickLower
            tickUpper = raw.tickUpper
            tickOutsideLower = lower
            tickOutsideUpper = upper
            token0 = raw.token0
            token1 = raw.token1
            tokensOwed = raw.tokensOwed
        }
    }

    struct PoolState: Sendable {
        let feeGrowthGlobal: UniswapV3Math.FeeGrowth
        let sqrtPrice: BigUInt
        let tick: Int
    }

    enum ReadResult: Sendable {
        case failed
        case live(State)
        case removed
    }

    struct LivePosition: Sendable {
        let candidate: Candidate
        let chainId: UInt64
        let state: State
    }

    struct RawPosition {
        let fee: UInt32
        let feeGrowthInsideLast: UniswapV3Math.FeeGrowth
        let liquidity: BigUInt
        let tickLower: Int
        let tickUpper: Int
        let token0: EthereumAddress
        let token1: EthereumAddress
        let tokensOwed: UniswapV3Position.Amounts
    }

    struct PoolKey: Hashable {
        let fee: UInt32
        let token0: EthereumAddress
        let token1: EthereumAddress

        init(_ raw: RawPosition) {
            fee = raw.fee
            token0 = raw.token0
            token1 = raw.token1
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.fee == rhs.fee && lhs.token0 == rhs.token0 && lhs.token1 == rhs.token1
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(fee)
            hasher.combine(token0.string.lowercased())
            hasher.combine(token1.string.lowercased())
        }
    }

    /// A position with its pool address.
    private struct Located {
        let key: String
        let pool: EthereumAddress
        let raw: RawPosition
    }

    /// Ownership, position, pool and tick reads at `block`, in three Multicall rounds.
    static func readStates(
        _ candidates: [Candidate],
        owner: String,
        deployment: UniswapV3Deployment,
        reader: any DefiEVMReader,
        at block: BlockRef
    ) async throws -> [String: ReadResult] {
        guard !candidates.isEmpty else {
            return [:]
        }

        let owned = try await readOwnedPositions(
            candidates, owner: owner, deployment: deployment, reader: reader, at: block
        )

        var results = owned.results
        let raws = owned.raws
        let pools = try await readPools(Array(raws.values), deployment: deployment, reader: reader, at: block)
        let located = raws.compactMap { key, raw in
            pools[PoolKey(raw)].map { Located(key: key, pool: $0, raw: raw) }
        }

        for key in raws.keys where !located.contains(where: { $0.key == key }) {
            results[key] = .failed
        }

        for (key, result) in try await readPoolStates(located, reader: reader, at: block) {
            results[key] = result
        }

        return results
    }

    /// Round 1: `ownerOf` and `positions` per token.
    private static func readOwnedPositions(
        _ candidates: [Candidate],
        owner: String,
        deployment: UniswapV3Deployment,
        reader: any DefiEVMReader,
        at block: BlockRef
    ) async throws -> (results: [String: ReadResult], raws: [String: RawPosition]) {
        let manager = deployment.positionManager
        let calls = candidates.flatMap { candidate in
            [
                EVMCall(data: Self.encode("ownerOf(uint256)", candidate.tokenId), target: manager),
                EVMCall(data: Self.encode("positions(uint256)", candidate.tokenId), target: manager)
            ]
        }

        let returned = try await reader.call(calls, at: block)
        var results: [String: ReadResult] = [:]
        var raws: [String: RawPosition] = [:]

        for (index, candidate) in candidates.enumerated() {
            switch Self.ownership(returned[2 * index], owner: owner) {
            case .failed:
                results[candidate.key] = .failed

            case .removed:
                results[candidate.key] = .removed

            case .owned:
                if let raw = Self.decodePosition(returned[2 * index + 1]) {
                    raws[candidate.key] = raw
                } else {
                    results[candidate.key] = .failed
                }
            }
        }

        return (results, raws)
    }

    /// Round 2: the factory's pool for each distinct token pair and fee.
    private static func readPools(
        _ raws: [RawPosition],
        deployment: UniswapV3Deployment,
        reader: any DefiEVMReader,
        at block: BlockRef
    ) async throws -> [PoolKey: EthereumAddress] {
        let keys = Array(Set(raws.map(PoolKey.init)))
        let calls = keys.map { key in
            EVMCall(
                data: EthereumABI.encodeCall(
                    selector: EthereumABI.selector("getPool(address,address,uint24)"),
                    parameters: [.address(key.token0), .address(key.token1), .uint256(BigUInt(key.fee))]
                ),
                target: deployment.factory
            )
        }

        var pools: [PoolKey: EthereumAddress] = [:]

        for (key, result) in zip(keys, try await reader.call(calls, at: block)) {
            if result.isSuccess, let word = EthereumABI.words(result.data).first,
               let pool = try? EthereumABI.decodeAddress(word), pool != .zero {
                pools[key] = pool
            }
        }

        return pools
    }

    /// Round 3: each pool's price and global fee growth, and each position's tick fee growth.
    private static func readPoolStates(
        _ located: [Located],
        reader: any DefiEVMReader,
        at block: BlockRef
    ) async throws -> [String: ReadResult] {
        let pools = Array(Dictionary(located.map { (
            $0.pool.string.lowercased(),
            $0.pool
        ) }) { first, _ in first }.values)
        let poolCalls = pools.flatMap { pool in
            ["slot0()", "feeGrowthGlobal0X128()", "feeGrowthGlobal1X128()"].map {
                EVMCall(data: EthereumABI.encodeCall(selector: EthereumABI.selector($0)), target: pool)
            }
        }

        let tickCalls = located.flatMap { position in
            [position.raw.tickLower, position.raw.tickUpper].map { EVMCall(
                data: Self.encodeTick($0),
                target: position.pool
            ) }
        }

        let returned = try await reader.call(poolCalls + tickCalls, at: block)
        var poolStates: [String: PoolState] = [:]

        for (index, pool) in pools.enumerated() {
            poolStates[pool.string.lowercased()] = Self.decodePool(Array(returned[3 * index ..< 3 * index + 3]))
        }

        var results: [String: ReadResult] = [:]

        for (index, position) in located.enumerated() {
            let base = poolCalls.count + 2 * index

            guard let poolState = poolStates[position.pool.string.lowercased()],
                  let lower = Self.decodeTickOutside(returned[base]),
                  let upper = Self.decodeTickOutside(returned[base + 1])
            else {
                results[position.key] = .failed
                continue
            }

            results[position.key] = .live(State(raw: position.raw, pool: poolState, lower: lower, upper: upper))
        }

        return results
    }
}
