import WalletKit

struct UniswapV3PriceSource: PriceSource {
    // swiftlint:disable force_try
    private static let factory = try! EthereumAddress(string: "0x1f98431c8ad98523631ae4a59f267346ea31f984")
    private static let usdc = try! EthereumAddress(string: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48")
    // swiftlint:enable force_try

    private static let feeTiers: [UInt32] = [100, 500, 3_000, 10_000]

    let clientProvider: BlockchainClientProvider

    func usdPrice(_ token: Token, rpcURL: URL) async throws -> Decimal? {
        guard case let .evm(blockchain)? = token.blockchain, let address = token.address else {
            return nil
        }

        let client = try clientProvider.ethereumClient(blockchain: .evm(blockchain), rpcURL: rpcURL)
        let token = try EthereumAddress(string: address)
        let pool = try await pool(token: token, client: client)
        return Decimal(try await twapPrice(token: token, pool: pool, client: client))
    }

    private func factoryPool(
        token: EthereumAddress,
        fee: UInt32,
        client: EthereumRPCClient
    ) async throws -> EthereumAddress {
        let data = EthereumABI.encodeCall(
            selector: EthereumABI.selector("getPool(address,address,uint24)"),
            parameters: [.address(token), .address(Self.usdc), .uint256(BigUInt(fee))]
        )

        guard let word = EthereumABI.words(try await client.call(to: Self.factory, data: data)).first else {
            throw BlockchainClientError.decodingFailed(reason: "empty getPool(address,address,uint24) response")
        }

        return try EthereumABI.decodeAddress(word)
    }

    private func pool(token: EthereumAddress, client: EthereumRPCClient) async throws -> EthereumAddress {
        let candidates = try await withThrowingTaskGroup(
            of: (pool: EthereumAddress, liquidity: BigUInt)?.self
        ) { group in
            for tier in Self.feeTiers {
                group.addTask {
                    let pool = try await factoryPool(token: token, fee: tier, client: client)

                    guard pool != EthereumAddress.zero else {
                        return nil
                    }

                    return (pool, try await poolLiquidity(pool, client: client))
                }
            }

            var found: [(pool: EthereumAddress, liquidity: BigUInt)] = []

            for try await candidate in group {
                if let candidate {
                    found.append(candidate)
                }
            }

            return found
        }

        guard let best = candidates.max(by: { $0.liquidity < $1.liquidity }), best.liquidity > 0 else {
            throw BlockchainClientError.decodingFailed(
                reason: "no Uniswap V3 pool with any liquidity exists for this pair at any standard fee tier"
            )
        }

        return best.pool
    }

    private func poolLiquidity(_ pool: EthereumAddress, client: EthereumRPCClient) async throws -> BigUInt {
        let data = EthereumABI.encodeCall(selector: EthereumABI.selector("liquidity()"))

        guard let word = EthereumABI.words(try await client.call(to: pool, data: data)).first else {
            throw BlockchainClientError.decodingFailed(reason: "empty liquidity() response")
        }

        return EthereumABI.decodeUInt256(word)
    }

    private func poolTokens(
        _ pool: EthereumAddress,
        client: EthereumRPCClient
    ) async throws -> (EthereumAddress, EthereumAddress) {
        async let token0Data = client.call(
            to: pool,
            data: EthereumABI.encodeCall(selector: EthereumABI.selector("token0()"))
        )

        async let token1Data = client.call(
            to: pool,
            data: EthereumABI.encodeCall(selector: EthereumABI.selector("token1()"))
        )

        guard let token0Word = EthereumABI.words(try await token0Data).first,
              let token1Word = EthereumABI.words(try await token1Data).first
        else {
            throw BlockchainClientError.decodingFailed(reason: "empty token0() or token1() response")
        }

        return try (EthereumABI.decodeAddress(token0Word), EthereumABI.decodeAddress(token1Word))
    }

    private func twapPrice(
        token: EthereumAddress,
        pool: EthereumAddress,
        client: EthereumRPCClient,
        period: UInt32 = 300
    ) async throws -> Double {
        guard period > 0 else {
            throw BlockchainClientError.decodingFailed(reason: "period must be greater than zero")
        }

        let observeData = EthereumABI.selector("observe(uint32[])")
            + abiWord(32)
            + abiWord(2)
            + abiWord(BigUInt(period))
            + abiWord(0)

        async let poolTokens = poolTokens(pool, client: client)
        async let observeCall = client.call(to: pool, data: observeData)

        let (token0, token1) = try await poolTokens

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

        if delta < 0, delta % periodValue != 0 {
            meanTick -= 1
        }

        guard let tick = Int(exactly: meanTick) else {
            throw BlockchainClientError.decodingFailed(reason: "mean tick out of range: \(meanTick)")
        }

        async let tokenDecimalsCall = client.call(
            to: token,
            data: EthereumABI.encodeCall(selector: EthereumABI.selector("decimals()"))
        )

        async let quoteDecimalsCall = client.call(
            to: quoteToken,
            data: EthereumABI.encodeCall(selector: EthereumABI.selector("decimals()"))
        )

        guard let tokenDecimalsWord = EthereumABI.words(try await tokenDecimalsCall).first,
              let tokenDecimals = Int(exactly: EthereumABI.decodeUInt256(tokenDecimalsWord)),
              let quoteDecimalsWord = EthereumABI.words(try await quoteDecimalsCall).first,
              let quoteDecimals = Int(exactly: EthereumABI.decodeUInt256(quoteDecimalsWord))
        else {
            throw BlockchainClientError.decodingFailed(reason: "empty or invalid decimals() response")
        }

        let rawToken0InToken1 = pow(1.0001, Double(tick))
        let decimalsAdjustment = pow(10, Double(tokenDecimals - quoteDecimals))

        return token == token0
            ? rawToken0InToken1 * decimalsAdjustment
            : decimalsAdjustment / rawToken0InToken1
    }

    private func abiWord(_ value: BigUInt) -> Data {
        let bytes = value.serialize()
        return Data(repeating: 0, count: 32 - bytes.count) + bytes
    }
}
