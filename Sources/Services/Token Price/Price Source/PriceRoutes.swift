import WalletKit

/// Which sources may price each chain's tokens, in the order they're tried, followed by the
/// universal sources every token falls back to.
struct PriceRoutes: Sendable {
    let chains: [Blockchain: [any PriceSource]]
    let universal: [any PriceSource]

    func sources(for blockchain: Blockchain?) -> [any PriceSource] {
        (blockchain.flatMap { chains[Self.routeKey($0)] } ?? []) + universal
    }

    /// A custom EVM chain with a known id uses that chain's route.
    private static func routeKey(_ blockchain: Blockchain) -> Blockchain {
        guard case let .evm(.custom(chainId)) = blockchain else {
            return blockchain
        }

        return .evm(EVMBlockchain(chainId: chainId))
    }
}

extension PriceRoutes {
    /// Mainnet routes. Testnets and chains without an entry only reach the universal sources.
    static func live(clientProvider: BlockchainClientProvider) -> PriceRoutes {
        func evm(
            _ chain: EVMBlockchain,
            feeds: ChainlinkPriceSource.FeedLookup,
            uniswap: UniswapV3PriceSource.Deployment?
        ) -> (Blockchain, [any PriceSource]) {
            var sources: [any PriceSource] = [ChainlinkPriceSource(clientProvider: clientProvider, lookup: feeds)]

            if let uniswap {
                sources.append(UniswapV3PriceSource(clientProvider: clientProvider, deployment: uniswap))
            }

            return (.evm(chain), sources)
        }

        return PriceRoutes(
            chains: Dictionary(uniqueKeysWithValues: [
                evm(.arbitrum(.mainnet), feeds: .arbitrum, uniswap: .arbitrum),
                evm(.avalanche(.mainnet), feeds: .avalanche, uniswap: .avalanche),
                evm(.base(.mainnet), feeds: .base, uniswap: .base),
                evm(.bsc(.mainnet), feeds: .bsc, uniswap: .bsc),
                evm(.ethereum(.mainnet), feeds: .ens, uniswap: .ethereum),
                // HyperEVM's V3 factory exists but no liquid USD pair was found; Mantle has no V3.
                evm(.hyperEVM(.mainnet), feeds: .hyperEVM, uniswap: nil),
                evm(.mantle(.mainnet), feeds: .mantle, uniswap: nil),
                evm(.monad(.mainnet), feeds: .monad, uniswap: .monad),
                evm(.optimism(.mainnet), feeds: .optimism, uniswap: .optimism),
                evm(.polygon(.mainnet), feeds: .polygon, uniswap: .polygon),
                evm(.robinhood(.mainnet), feeds: .robinhood, uniswap: .robinhood),
                evm(.unichain(.mainnet), feeds: .unichain, uniswap: .unichain),
                (.sui(.mainnet), [CetusPriceSource(clientProvider: clientProvider)])
            ]),
            universal: [CoinGeckoPriceSource()]
        )
    }
}
