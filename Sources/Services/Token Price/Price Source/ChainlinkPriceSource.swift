import WalletKit

struct ChainlinkPriceSource: PriceSource {
    // swiftlint:disable force_try
    private static let ensRegistry = try! EthereumAddress(string: "0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e")
    // swiftlint:enable force_try

    /// Slack added to a feed's heartbeat before its answer counts as stale.
    private static let heartbeatGrace: TimeInterval = 15 * 60
    /// How far past the device clock an `updatedAt` may be; beyond it a slow clock could hide staleness.
    private static let maxClockSkew: TimeInterval = 5 * 60
    /// Every Ethereum crypto/USD feed in Chainlink's directory has a heartbeat of at most 24 hours.
    private static let ensHeartbeat: TimeInterval = 24 * 60 * 60

    let clientProvider: BlockchainClientProvider
    let lookup: FeedLookup
    let now: @Sendable () -> Date

    init(
        clientProvider: BlockchainClientProvider,
        lookup: FeedLookup = .ens,
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

        let client = try clientProvider.ethereumClient(blockchain: .evm(blockchain), rpcURL: rpcURL)
        let feed: EthereumAddress
        let heartbeat: TimeInterval

        switch lookup {
        case .ens:
            feed = try await chainlinkFeedAddress(base: token.symbol, client: client)
            heartbeat = Self.ensHeartbeat
        case let .table(native, tokens):
            guard let entry = token.isNativeToken ? native : token.address.flatMap({ tokens[$0.lowercased()] }) else {
                return nil
            }

            feed = try EthereumAddress(string: entry.address)
            heartbeat = entry.heartbeat
        }

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

    private func chainlinkFeedAddress(base: String, client: EthereumRPCClient) async throws -> EthereumAddress {
        try await resolveENSName("\(base.lowercased())-usd.data.eth", client: client)
    }

    private func latestRoundData(feed: EthereumAddress, client: EthereumRPCClient) async throws -> ChainlinkRoundData {
        let data = EthereumABI.encodeCall(selector: EthereumABI.selector("latestRoundData()"))
        let words = EthereumABI.words(try await client.call(to: feed, data: data))

        guard words.count >= 5 else {
            throw BlockchainClientError.decodingFailed(reason: "expected 5 words, got \(words.count)")
        }

        guard let updatedAt = Int(exactly: EthereumABI.decodeUInt256(words[3])) else {
            throw BlockchainClientError.decodingFailed(reason: "price feed updatedAt out of range")
        }

        return ChainlinkRoundData(answer: EthereumABI.decodeInt256(words[1]), updatedAt: TimeInterval(updatedAt))
    }

    private func resolveENSName(_ name: String, client: EthereumRPCClient) async throws -> EthereumAddress {
        let node = namehash(name)
        let resolverData = EthereumABI.encodeCall(
            selector: EthereumABI.selector("resolver(bytes32)"),
            parameters: [.bytes32(node)]
        )

        guard let resolverWord = EthereumABI.words(
            try await client.call(to: Self.ensRegistry, data: resolverData)
        ).first else {
            throw BlockchainClientError.decodingFailed(reason: "empty resolver(bytes32) response")
        }

        let resolver = try EthereumABI.decodeAddress(resolverWord)

        guard resolver != EthereumAddress.zero else {
            throw BlockchainClientError.decodingFailed(reason: "ENS name has no resolver set")
        }

        let addressData = EthereumABI.encodeCall(
            selector: EthereumABI.selector("addr(bytes32)"),
            parameters: [.bytes32(node)]
        )

        guard let addressWord = EthereumABI.words(try await client.call(to: resolver, data: addressData)).first else {
            throw BlockchainClientError.decodingFailed(reason: "empty addr(bytes32) response")
        }

        let address = try EthereumABI.decodeAddress(addressWord)

        guard address != EthereumAddress.zero else {
            throw BlockchainClientError.decodingFailed(reason: "ENS resolver has no address set")
        }

        return address
    }

    private func namehash(_ name: String) -> Data {
        name.split(separator: ".").reversed().reduce(Data(repeating: 0, count: 32)) { node, label in
            EthereumABI.keccak256(node + EthereumABI.keccak256(Data(label.utf8)))
        }
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
        /// `<symbol>-usd.data.eth` via ENS, Ethereum mainnet only.
        case ens
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
