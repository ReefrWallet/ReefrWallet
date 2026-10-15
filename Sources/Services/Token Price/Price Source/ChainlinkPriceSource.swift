import WalletKit

struct ChainlinkPriceSource: PriceSource {
    // swiftlint:disable force_try
    private static let ensRegistry = try! EthereumAddress(string: "0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e")
    // swiftlint:enable force_try

    let clientProvider: BlockchainClientProvider

    func usdPrice(_ token: Token, rpcURL: URL) async throws -> Decimal? {
        guard case let .evm(blockchain)? = token.blockchain else {
            return nil
        }

        let client = try clientProvider.ethereumClient(blockchain: .evm(blockchain), rpcURL: rpcURL)
        let feed = try await chainlinkFeedAddress(base: token.symbol, client: client)
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

        let answer = try await round.answer

        guard answer > 0 else {
            throw BlockchainClientError.decodingFailed(reason: "non-positive price feed answer")
        }

        return Decimal(sign: .plus, exponent: -decimals, significand: Decimal(answer))
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

        return ChainlinkRoundData(answer: EthereumABI.decodeInt256(words[1]))
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

private struct ChainlinkRoundData {
    let answer: BigInt
}
