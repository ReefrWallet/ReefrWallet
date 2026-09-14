//
//  EthereumRPCClient+Utilities.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 17/08/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation

extension EthereumRPCClient {
    // swiftlint:disable force_try
    /// Ethereum mainnet's ENS Registry contract address — the default
    /// ``resolveENSName(_:ensRegistry:)`` resolves against. Pass a
    /// different registry to resolve an ENS-compatible name against a
    /// different deployment instead, e.g. an L2's own registry.
    public static let mainnetENSRegistry = try! EthereumAddress(string: "0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e")
    // swiftlint:enable force_try

    /// Resolves `name` — a dotted ENS name (e.g. `"vitalik.eth"`) — to the
    /// address it's registered to, via `ensRegistry`'s `resolver(bytes32)`
    /// and that resolver's `addr(bytes32)`.
    ///
    /// - Parameters:
    ///   - name: The dotted ENS name to resolve.
    ///   - ensRegistry: The ENS Registry contract to resolve against.
    ///     Defaults to ``mainnetENSRegistry``; pass an L2's own registry
    ///     to resolve an ENS-compatible name deployed there instead.
    /// - Returns: The address `name` resolves to.
    /// - Throws: ``BlockchainClientError/decodingFailed(reason:)`` if
    ///   `name` has no resolver set or the resolver has no address set
    ///   for it, or ``BlockchainClientError`` on a transport, RPC, or
    ///   other decoding failure.
    public func resolveENSName(
        _ name: String,
        ensRegistry: EthereumAddress = mainnetENSRegistry
    ) async throws -> EthereumAddress {
        let zeroAddress = try EthereumAddress(rawBytes: Data(repeating: 0, count: 20))

        let node = EthereumENS.namehash(name)

        let resolverData = EthereumABI.encodeCall(
            selector: EthereumABI.selector("resolver(bytes32)"),
            parameters: [.bytes32(node)]
        )
        let resolverResult = try await call(to: ensRegistry, data: resolverData)

        guard let resolverWord = EthereumABI.words(resolverResult).first else {
            throw BlockchainClientError.decodingFailed(reason: "empty resolver(bytes32) response")
        }

        let resolver = try EthereumABI.decodeAddress(resolverWord)
        guard resolver != zeroAddress else {
            throw BlockchainClientError.decodingFailed(reason: "ENS name has no resolver set")
        }

        let addrData = EthereumABI.encodeCall(
            selector: EthereumABI.selector("addr(bytes32)"),
            parameters: [.bytes32(node)]
        )
        let addrResult = try await call(to: resolver, data: addrData)

        guard let addrWord = EthereumABI.words(addrResult).first else {
            throw BlockchainClientError.decodingFailed(reason: "empty addr(bytes32) response")
        }

        let resolved = try EthereumABI.decodeAddress(addrWord)
        guard resolved != zeroAddress else {
            throw BlockchainClientError.decodingFailed(reason: "ENS resolver has no address set")
        }

        return resolved
    }

    /// Resolves a Chainlink price feed's contract address for a `base`/
    /// `quote` symbol pair via Chainlink's ENS naming convention —
    /// `<base>-<quote>.data.eth` (e.g. `"eth-usd.data.eth"`) — resolved
    /// through ``resolveENSName(_:ensRegistry:)``.
    ///
    /// - Parameters:
    ///   - base: The feed's base asset symbol, e.g. `"ETH"`. Matched
    ///     case-insensitively against the ENS name.
    ///   - quote: The feed's quote asset symbol. Defaults to `"USD"`.
    ///   - ensRegistry: The ENS Registry contract to resolve against.
    ///     Defaults to ``mainnetENSRegistry``; pass an L2's own registry
    ///     to resolve a feed published there under the same naming
    ///     convention instead.
    /// - Returns: The feed's `AggregatorV3Interface` contract address.
    /// - Throws: ``BlockchainClientError/decodingFailed(reason:)`` if the
    ///   ENS name has no resolver set or the resolver has no address set
    ///   for it, or ``BlockchainClientError`` on a transport, RPC, or
    ///   other decoding failure.
    public func chainlinkFeedAddress(
        base: String,
        quote: String = "USD",
        ensRegistry: EthereumAddress = mainnetENSRegistry
    ) async throws -> EthereumAddress {
        try await resolveENSName("\(base.lowercased())-\(quote.lowercased()).data.eth", ensRegistry: ensRegistry)
    }

    /// Reads a Chainlink price feed's latest round — `latestRoundData()`.
    ///
    /// - Parameter feed: The `AggregatorV3Interface`-conforming feed
    ///   contract address.
    /// - Returns: The feed's latest round data.
    /// - Throws: ``BlockchainClientError`` on a transport, RPC, or
    ///   decoding failure.
    public func latestRoundData(feed: EthereumAddress) async throws -> ChainlinkRoundData {
        let data = EthereumABI.encodeCall(selector: EthereumABI.selector("latestRoundData()"))
        let result = try await call(to: feed, data: data)
        let words = EthereumABI.words(result)

        guard words.count >= 5 else {
            throw BlockchainClientError.decodingFailed(reason: "expected 5 words, got \(words.count)")
        }

        return ChainlinkRoundData(
            roundId: EthereumABI.decodeUInt256(words[0]),
            answer: EthereumABI.decodeInt256(words[1]),
            startedAt: EthereumABI.decodeUInt256(words[2]),
            updatedAt: EthereumABI.decodeUInt256(words[3]),
            answeredInRound: EthereumABI.decodeUInt256(words[4])
        )
    }

    /// Reads a Uniswap V3 `pool`'s time-weighted average price for
    /// `token` over the last `period` seconds — the geometric-mean price
    /// Uniswap's own oracle produces, via `observe(uint32[])`'s
    /// tick-cumulative accumulators (no swap/mint/burn needed to read
    /// it).
    ///
    /// A tick's price — `1.0001^tick` — is defined as the pool's
    /// `token0` priced in `token1` (raw, smallest-unit terms); averaging
    /// in tick space and only exponentiating once is exactly the
    /// geometric mean of the price over `period`, which is what makes
    /// this resistant to single-block manipulation the way a naive
    /// arithmetic-mean-of-spot-prices oracle wouldn't be. `token` must be
    /// one of `pool`'s two tokens — whichever one it isn't becomes the
    /// quote asset the returned price is denominated in.
    ///
    /// - Parameters:
    ///   - token: The token to price — must be `pool`'s `token0` or
    ///     `token1`.
    ///   - pool: The Uniswap V3 pool contract address (a specific
    ///     token/quote pair at a specific fee tier).
    ///   - period: The averaging window, in seconds. Defaults to `30`.
    /// - Returns: The average price of one (human-unit) `token`, in
    ///   human-unit terms of the pool's other token.
    /// - Throws: ``BlockchainClientError/decodingFailed(reason:)`` if
    ///   `period` is `0`, `token` is neither of `pool`'s two tokens, or
    ///   `observe` didn't return exactly 2 tick cumulatives, or
    ///   ``BlockchainClientError`` on a transport, RPC, or other decoding
    ///   failure.
    public func uniswapV3TWAPPrice( // swiftlint:disable:this function_body_length
        token: EthereumAddress,
        pool: EthereumAddress,
        period: UInt32 = 30
    ) async throws -> Double {
        guard period > 0 else {
            throw BlockchainClientError.decodingFailed(reason: "period must be greater than zero")
        }

        // observe(uint32[2]) — a single dynamic-array parameter: offset
        // (always 0x20, the one and only parameter), length (2), then
        // secondsAgos = [period, 0], each ABI-encoded as a full word like
        // any other integer type wide-narrower-than-256-bits.
        let observeData = EthereumABI.selector("observe(uint32[])")
            + EthereumABIValue.uint256(32).word
            + EthereumABIValue.uint256(2).word
            + EthereumABIValue.uint256(BigUInt(period)).word
            + EthereumABIValue.uint256(0).word

        async let token0Call = call(to: pool, data: EthereumABI.encodeCall(selector: EthereumABI.selector("token0()")))
        async let token1Call = call(to: pool, data: EthereumABI.encodeCall(selector: EthereumABI.selector("token1()")))
        async let observeCall = call(to: pool, data: observeData)

        guard let token0Word = EthereumABI.words(try await token0Call).first else {
            throw BlockchainClientError.decodingFailed(reason: "empty token0() response")
        }
        guard let token1Word = EthereumABI.words(try await token1Call).first else {
            throw BlockchainClientError.decodingFailed(reason: "empty token1() response")
        }

        let token0 = try EthereumABI.decodeAddress(token0Word)
        let token1 = try EthereumABI.decodeAddress(token1Word)
        guard token == token0 || token == token1 else {
            throw BlockchainClientError.decodingFailed(reason: "token is neither of the pool's two tokens")
        }
        let quoteToken = token == token0 ? token1 : token0

        let tickCumulatives = try EthereumABI.decodeInt256Array(try await observeCall)
        guard tickCumulatives.count == 2 else {
            throw BlockchainClientError.decodingFailed(reason: "expected 2 tickCumulatives, got \(tickCumulatives.count)")
        }

        let periodValue = BigInt(period)
        let delta = tickCumulatives[1] - tickCumulatives[0]
        var meanTick = delta / periodValue
        // Always round to negative infinity, matching Uniswap's own
        // OracleLibrary.consult — plain integer division truncates
        // toward zero instead, which is the wrong rounding direction for
        // a negative, inexact quotient.
        if delta < 0, delta % periodValue != 0 {
            meanTick -= 1
        }

        guard let tick = Int(exactly: meanTick) else {
            throw BlockchainClientError.decodingFailed(reason: "mean tick out of range: \(meanTick)")
        }

        async let tokenDecimalsCall = call(
            to: token,
            data: EthereumABI.encodeCall(selector: EthereumABI.selector("decimals()"))
        )

        async let quoteDecimalsCall = call(
            to: quoteToken,
            data: EthereumABI.encodeCall(selector: EthereumABI.selector("decimals()"))
        )

        guard let tokenDecimalsWord = EthereumABI.words(try await tokenDecimalsCall).first,
              let tokenDecimals = Int(exactly: EthereumABI.decodeUInt256(tokenDecimalsWord))
        else {
            throw BlockchainClientError.decodingFailed(reason: "empty or invalid decimals() response for token")
        }

        guard let quoteDecimalsWord = EthereumABI.words(try await quoteDecimalsCall).first,
              let quoteDecimals = Int(exactly: EthereumABI.decodeUInt256(quoteDecimalsWord))
        else {
            throw BlockchainClientError.decodingFailed(reason: "empty or invalid decimals() response for quote token")
        }

        // Raw price of one smallest-unit of token0 in smallest-units of
        // token1; adjusting by each side's decimals gives the
        // human-readable price in the requested direction.
        let rawToken0InToken1 = pow(1.0001, Double(tick))
        let decimalsAdjustment = pow(10, Double(tokenDecimals - quoteDecimals))

        return token == token0 ? rawToken0InToken1 * decimalsAdjustment : decimalsAdjustment / rawToken0InToken1
    }
}
