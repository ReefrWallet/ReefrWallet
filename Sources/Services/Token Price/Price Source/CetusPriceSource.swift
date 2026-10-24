import WalletKit

/// Cetus's USDC/SUI pool provides the app's native SUI mainnet quote.
struct CetusPriceSource: PriceSource {
    private static let pool = "0xb8d7d9e66a60c239e7a60110efcf8de6c705580ed924d0dde141f4a0e2c90105"
    private static let suiCoinType = "0x2::sui::SUI"

    let clientProvider: BlockchainClientProvider

    var id: String {
        "cetus"
    }

    func usdPrice(_ token: Token, rpcURL: URL) async throws -> Decimal? {
        guard case let .sui(network)? = token.blockchain, network == .mainnet, token.isNativeToken else {
            return nil
        }

        let client = try clientProvider.suiClient(blockchain: .sui(network), rpcURL: rpcURL)
        return Decimal(try await cetusPoolPrice(client: client, pool: Self.pool, token: Self.suiCoinType))
    }
}

private extension CetusPriceSource {
    func cetusPoolPrice(client: SuiGRPCClient, pool: String, token: String) async throws -> Double {
        let poolObject = try await client.object(id: pool, readMask: ["object_type", "json"])
        let coinTypes = try MoveTypeTag.genericTypeArguments(of: poolObject.objectType)

        guard coinTypes.count == 2 else {
            throw BlockchainClientError.decodingFailed(
                reason: "expected a Pool<CoinTypeA, CoinTypeB> object, got \(poolObject.objectType)"
            )
        }

        let coinTypeA = try MoveTypeTag.canonicalCoinType(coinTypes[0])
        let coinTypeB = try MoveTypeTag.canonicalCoinType(coinTypes[1])
        let normalizedToken = try MoveTypeTag.canonicalCoinType(token)

        guard normalizedToken == coinTypeA || normalizedToken == coinTypeB else {
            throw BlockchainClientError.decodingFailed(reason: "token is neither of the pool's two coin types")
        }

        guard case .stringValue(let sqrtPriceString)? = poolObject.json.structValue.fields["current_sqrt_price"]?.kind,
              let sqrtPriceX64 = BigUInt(sqrtPriceString)
        else {
            throw BlockchainClientError.decodingFailed(reason: "pool object has no readable current_sqrt_price")
        }

        async let coinACall = client.coinInfo(coinType: coinTypeA)
        let coinADecimals = try await coinACall.decimals

        async let coinBCall = client.coinInfo(coinType: coinTypeB)
        let coinBDecimals = try await coinBCall.decimals

        let tokenDecimals = normalizedToken == coinTypeA ? coinADecimals : coinBDecimals
        let quoteDecimals = normalizedToken == coinTypeA ? coinBDecimals : coinADecimals
        let sqrtPrice = Double(sqrtPriceX64) / pow(2, 64)
        let rawCoinAInCoinB = sqrtPrice * sqrtPrice
        let decimalsAdjustment = pow(10, Double(Int(tokenDecimals) - Int(quoteDecimals)))

        return normalizedToken == coinTypeA
            ? rawCoinAInCoinB * decimalsAdjustment
            : decimalsAdjustment / rawCoinAInCoinB
    }
}
