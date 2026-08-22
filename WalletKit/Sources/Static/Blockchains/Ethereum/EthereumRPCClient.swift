//
//  EthereumRPCClient.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 17/08/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation

/// A client for an Ethereum JSON-RPC node — native-token balance,
/// arbitrary read-only contract calls, and broadcasting an already-signed
/// transaction. Pairs with ``EthereumPKeySigner``/``EthereumTrezorSigner``,
/// which produce the signed transaction bytes ``broadcast(_:)`` sends;
/// this client builds no transactions of its own.
public struct EthereumRPCClient {
    /// The EVM chain ID this client's endpoint is expected to serve —
    /// descriptive only. Unlike signing, reading a balance or broadcasting
    /// to the wrong network is a configuration/UX concern, not a replay-
    /// protection one, so this isn't enforced against responses.
    public let chainId: UInt64

    private let rpc: JSONRPCClient

    /// Creates a client for the node at `endpoint`.
    ///
    /// - Parameters:
    ///   - endpoint: The node's JSON-RPC HTTPS endpoint.
    ///   - chainId: The EVM chain ID this endpoint is expected to serve.
    ///     Defaults to `1` (Ethereum mainnet).
    ///   - session: The `URLSession` to issue requests on. Defaults to
    ///     `.shared`.
    public init(endpoint: URL, chainId: UInt64 = 1, session: URLSession = .shared) {
        self.chainId = chainId
        rpc = JSONRPCClient(endpoint: endpoint, session: session)
    }

    /// Broadcasts an already-signed transaction — `eth_sendRawTransaction`.
    ///
    /// - Parameter signedTransaction: The RLP-encoded signed transaction,
    ///   e.g. from ``EthereumPKeySigner/sign(transaction:)``.
    /// - Returns: The transaction hash.
    /// - Throws: ``BlockchainClientError`` on a transport, RPC, or
    ///   decoding failure.
    public func broadcast(_ signedTransaction: Data) async throws -> String {
        try await rpc.call(method: "eth_sendRawTransaction", params: [signedTransaction.hexEncoded])
    }

    /// Executes a read-only contract call against `address` — the
    /// general "execute a smart contract" entry point. ``erc20Balance``
    /// and ``latestRoundData`` are two worked examples built on this; a
    /// caller with a different contract computes its own call data via
    /// ``EthereumABI`` and calls this directly.
    ///
    /// - Parameters:
    ///   - address: The contract address to call.
    ///   - data: The ABI-encoded call data (selector + parameters).
    /// - Returns: The raw return data.
    /// - Throws: ``BlockchainClientError`` on a transport, RPC, or
    ///   decoding failure.
    public func call(to address: EthereumAddress, data: Data) async throws -> Data {
        let params = EthCallParams(to: address.string, data: data.hexEncoded)
        let hex: String = try await rpc.call(method: "eth_call", params: params)
        return try Data(hexString: hex)
    }

    /// Reads an ERC-20 `token`'s balance for `owner` — `balanceOf(address)`.
    ///
    /// - Parameters:
    ///   - token: The ERC-20 contract address.
    ///   - owner: The account to read the balance of.
    /// - Returns: The balance, in the token's smallest unit.
    /// - Throws: ``BlockchainClientError`` on a transport, RPC, or
    ///   decoding failure.
    public func erc20Balance(
        token: EthereumAddress,
        owner: EthereumAddress
    ) async throws -> BigUInt {
        let data = EthereumABI.encodeCall(
            selector: EthereumABI.selector("balanceOf(address)"),
            parameters: [.address(owner)]
        )

        let result = try await call(to: token, data: data)

        guard let word = EthereumABI.words(result).first else {
            throw BlockchainClientError.decodingFailed(reason: "empty balanceOf(address) response")
        }

        return EthereumABI.decodeUInt256(word)
    }

    /// Reads an ERC-20 `token`'s metadata — `name()`, `symbol()`, and
    /// `decimals()`.
    ///
    /// - Parameter token: The ERC-20 contract address.
    /// - Returns: The token's metadata.
    /// - Throws: ``BlockchainClientError`` on a transport, RPC, or
    ///   decoding failure.
    public func erc20TokenInfo(token: EthereumAddress) async throws -> TokenInfo {
        async let nameData = call(
            to: token,
            data: EthereumABI.encodeCall(selector: EthereumABI.selector("name()"))
        )

        async let symbolData = call(
            to: token,
            data: EthereumABI.encodeCall(selector: EthereumABI.selector("symbol()"))
        )

        async let decimalsData = call(
            to: token,
            data: EthereumABI.encodeCall(selector: EthereumABI.selector("decimals()"))
        )

        let name = try EthereumABI.decodeString(try await nameData)
        let symbol = try EthereumABI.decodeString(try await symbolData)

        guard let decimalsWord = EthereumABI.words(try await decimalsData).first,
              let decimals = UInt8(exactly: EthereumABI.decodeUInt256(decimalsWord))
        else {
            throw BlockchainClientError.decodingFailed(reason: "empty or invalid decimals() response")
        }

        return TokenInfo(name: name, symbol: symbol, decimals: decimals)
    }

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

    /// Reads `address`'s native-token (ETH) balance, in wei.
    ///
    /// - Parameter address: The address to read the balance of.
    /// - Returns: The balance, in wei.
    /// - Throws: ``BlockchainClientError`` on a transport, RPC, or
    ///   decoding failure.
    public func nativeBalance(of address: EthereumAddress) async throws -> BigUInt {
        let hex: String = try await rpc.call(method: "eth_getBalance", params: [address.string, "latest"])

        // `eth_getBalance` returns Ethereum's "Quantity" hex encoding —
        // minimal digits, no leading zeros, so (unlike "Data" hex —
        // addresses, calldata, raw tx — which is always byte-aligned) an
        // odd digit count is valid (e.g. "0x1" for 1 wei). Parsed as a
        // plain hex integer, not through `Data(hexString:)`.
        let body = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex

        guard let balance = BigUInt(body, radix: 16) else {
            throw BlockchainClientError.decodingFailed(reason: "invalid quantity hex: \(hex)")
        }

        return balance
    }

    /// Reads `address`'s current nonce — the number of transactions it has
    /// sent, i.e. the nonce to use for its next transaction.
    ///
    /// - Parameter address: The address to read the nonce of.
    /// - Returns: The nonce.
    /// - Throws: ``BlockchainClientError`` on a transport, RPC, or
    ///   decoding failure.
    public func nonce(of address: EthereumAddress) async throws -> UInt64 {
        let hex: String = try await rpc.call(method: "eth_getTransactionCount", params: [address.string, "latest"])

        let body = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex

        guard let nonce = UInt64(body, radix: 16) else {
            throw BlockchainClientError.decodingFailed(reason: "invalid quantity hex: \(hex)")
        }

        return nonce
    }
}

/// `eth_call`'s heterogeneous `[{to, data}, "latest"]` params — encoded
/// manually since the two elements aren't the same type.
private struct EthCallParams: Encodable {
    let to: String
    let data: String

    private struct CallObject: Encodable {
        let to: String
        let data: String
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(CallObject(to: to, data: data))
        try container.encode("latest")
    }
}
