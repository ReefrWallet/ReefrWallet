import WalletKit

struct ChainlinkPriceSource: PriceSource {
    /// Slack added to a feed's heartbeat before its answer counts as stale.
    private static let heartbeatGrace: TimeInterval = 15 * 60
    /// How far past the device clock an `updatedAt` may be; beyond it a slow clock could hide staleness.
    private static let maxClockSkew: TimeInterval = 5 * 60
    let clientProvider: BlockchainClientProvider
    let lookup: FeedLookup
    let now: @Sendable () -> Date

    init(
        clientProvider: BlockchainClientProvider,
        lookup: FeedLookup,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.clientProvider = clientProvider
        self.lookup = lookup
        self.now = now
    }

    var id: String {
        "chainlink"
    }

    func usdPrice(_ token: Token, rpcURL: URL) async throws -> Decimal? {
        guard case let .evm(blockchain)? = token.blockchain else {
            return nil
        }

        guard case let .table(native, tokens) = lookup,
              let entry = token.isNativeToken ? native : token.address.flatMap({ tokens[$0.lowercased()] })
        else {
            return nil
        }

        let client = try clientProvider.ethereumClient(blockchain: .evm(blockchain), rpcURL: rpcURL)
        let feed = try EthereumAddress(string: entry.address)
        let heartbeat = entry.heartbeat

        async let round = latestRoundData(feed: feed, client: client)

        async let decimalsData = client.call(
            to: feed,
            data: EthereumABI.encodeCall(selector: EthereumABI.selector("decimals()"))
        )

        guard let decimalsWord = EthereumABI.words(try await decimalsData).first,
              let decimals = Int(exactly: EthereumABI.decodeUInt256(decimalsWord))
        else {
            throw BlockchainClientError.decodingFailed(reason: "empty or invalid decimals() response for price feed")
        }

        let latest = try await round
        try validateFreshness(updatedAt: latest.updatedAt, heartbeat: heartbeat)

        guard latest.answer > 0 else {
            throw BlockchainClientError.decodingFailed(reason: "non-positive price feed answer")
        }

        return Decimal(sign: .plus, exponent: -decimals, significand: Decimal(latest.answer))
    }

    private func validateFreshness(updatedAt: TimeInterval, heartbeat: TimeInterval) throws {
        let age = now().timeIntervalSince1970 - updatedAt

        guard updatedAt > 0, age <= heartbeat + Self.heartbeatGrace, age >= -Self.maxClockSkew else {
            throw StaleAnswer(age: age, heartbeat: heartbeat)
        }
    }

    private func latestRoundData(feed: EthereumAddress, client: EthereumRPCClient) async throws -> ChainlinkRoundData {
        let data = EthereumABI.encodeCall(selector: EthereumABI.selector("latestRoundData()"))
        let words = EthereumABI.words(try await client.call(to: feed, data: data))

        guard !words.isEmpty else {
            throw BlockchainClientError.decodingFailed(reason: "empty latestRoundData() response")
        }

        guard words.count >= 5 else {
            throw BlockchainClientError.decodingFailed(reason: "expected 5 words, got \(words.count)")
        }

        guard let updatedAt = Int(exactly: EthereumABI.decodeUInt256(words[3])) else {
            throw BlockchainClientError.decodingFailed(reason: "price feed updatedAt out of range")
        }

        return ChainlinkRoundData(answer: EthereumABI.decodeInt256(words[1]), updatedAt: TimeInterval(updatedAt))
    }
}

extension ChainlinkPriceSource {
    /// A feed's proxy address and the longest it may go without updating.
    struct Feed: Sendable {
        let address: String
        let heartbeat: TimeInterval
    }

    /// How a token's feed is found.
    enum FeedLookup: Sendable {
        /// Fixed feeds: `native` for the chain's native token, `tokens` by lowercased contract address.
        case table(native: Feed, tokens: [String: Feed])
    }

    /// The feed's latest answer is older than its heartbeat allows, or dated impossibly far ahead.
    struct StaleAnswer: Swift.Error {
        let age: TimeInterval
        let heartbeat: TimeInterval
    }
}

private struct ChainlinkRoundData {
    let answer: BigInt
    let updatedAt: TimeInterval
}
