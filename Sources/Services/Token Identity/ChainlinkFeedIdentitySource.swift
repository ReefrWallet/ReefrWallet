import CryptoKit
import WalletKit

/// Identifies tokens listed in the Chainlink feed tables, whose contract addresses are checked by hand.
/// Needs no network, so these tokens stay identified offline and without any API key.
struct ChainlinkFeedIdentitySource: TokenIdentitySource {
    let feeds: [Blockchain: ChainlinkPriceSource.FeedLookup]

    var configurationVersion: String {
        let lines = feeds.flatMap { blockchain, lookup -> [String] in
            guard case let .table(native, tokens) = lookup else {
                return []
            }

            return ["\(blockchain)|\(native.address)"] + tokens.keys.map { "\(blockchain)|\($0)" }
        }

        let digest = SHA256.hash(data: Data(lines.sorted().joined(separator: "\n").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    var id: String {
        "chainlinkFeeds"
    }

    func identities(of tokens: [Token]) async -> [Result<TokenIdentity?, any Swift.Error>] {
        tokens.map { token in
            guard let blockchain = token.blockchain,
                  let address = token.address?.lowercased(),
                  case let .table(_, listed)? = feeds[PriceRoutes.routeKey(blockchain)],
                  listed[address] != nil
            else {
                return .success(nil)
            }

            return .success(TokenIdentity(externalId: nil))
        }
    }
}

extension ChainlinkFeedIdentitySource {
    /// The feed tables `PriceRoutes.live` prices from.
    static let live = ChainlinkFeedIdentitySource(feeds: [
        .evm(.arbitrum(.mainnet)): .arbitrum,
        .evm(.avalanche(.mainnet)): .avalanche,
        .evm(.base(.mainnet)): .base,
        .evm(.bsc(.mainnet)): .bsc,
        .evm(.ethereum(.mainnet)): .ethereum,
        .evm(.hyperEVM(.mainnet)): .hyperEVM,
        .evm(.mantle(.mainnet)): .mantle,
        .evm(.monad(.mainnet)): .monad,
        .evm(.optimism(.mainnet)): .optimism,
        .evm(.polygon(.mainnet)): .polygon,
        .evm(.robinhood(.mainnet)): .robinhood,
        .evm(.unichain(.mainnet)): .unichain
    ])
}
