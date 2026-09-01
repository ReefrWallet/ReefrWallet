import Foundation
import WalletKit

/// Caches and vends ``AnyBlockchainClient`` and
/// ``AnyBlockchainTransactionBuilder`` instances, one per ``WKBlockchain``.
/// Both ``BlockchainClientProtocol`` and ``BlockchainTransactionBuilderProtocol``
/// have `associatedtype Address`, making them PATs that cannot be used
/// directly as existentials. The `Any…` type-erasers bridge their concrete
/// `Address` types to `String` so callers don't need to know the chain type.
final class BlockchainClientProvider {
    private var clients: [WKBlockchain: AnyBlockchainClient] = [:]
    private var builders: [WKBlockchain: AnyBlockchainTransactionBuilder] = [:]

    /// Returns the cached ``AnyBlockchainClient`` for `blockchain`, creating
    /// one on the first call.
    ///
    /// - Throws: ``WalletKitError`` if the blockchain's endpoint URL is
    ///   invalid or the blockchain is not yet supported.
    func getClient(blockchain: WKBlockchain) throws -> AnyBlockchainClient {
        if let client = clients[blockchain] { return client }
        let client = try makeClient(blockchain: blockchain)
        clients[blockchain] = client
        return client
    }

    /// Returns the cached ``AnyBlockchainTransactionBuilder`` for `blockchain`,
    /// creating one on the first call.
    ///
    /// - Throws: ``WalletKitError`` if the blockchain's endpoint URL is
    ///   invalid or the blockchain is not yet supported.
    func getBuilder(blockchain: WKBlockchain) throws -> AnyBlockchainTransactionBuilder {
        if let builder = builders[blockchain] { return builder }
        let builder = try makeBuilder(blockchain: blockchain)
        builders[blockchain] = builder
        return builder
    }

    private func makeClient(blockchain: WKBlockchain) throws -> AnyBlockchainClient {
        let endpoint = blockchain.rpcURL

        switch blockchain {
        case let .evm(network):
            return AnyBlockchainClient(EthereumRPCClient(endpoint: endpoint, chainId: network.chainId))
        case .sui:
            guard let host = endpoint.host else {
                throw WalletKitError.invalidAddress(reason: "Invalid Sui endpoint: \(endpoint)")
            }
            return AnyBlockchainClient(
                SuiGRPCClient(host: host, port: endpoint.port ?? 443, useTLS: endpoint.scheme == "https")
            )
        default:
            throw WalletKitError.internalError(message: "Not implemented yet")
        }
    }

    private func makeBuilder(blockchain: WKBlockchain) throws -> AnyBlockchainTransactionBuilder {
        let endpoint = blockchain.rpcURL

        switch blockchain {
        case let .evm(network):
            let client = EthereumRPCClient(endpoint: endpoint, chainId: network.chainId)
            return AnyBlockchainTransactionBuilder(EthereumTransactionBuilder(client: client))
        case .sui:
            guard let host = endpoint.host else {
                throw WalletKitError.invalidAddress(reason: "Invalid Sui endpoint: \(endpoint)")
            }
            let client = SuiGRPCClient(
                host: host, port: endpoint.port ?? 443, useTLS: endpoint.scheme == "https"
            )
            return AnyBlockchainTransactionBuilder(SuiTransactionBuilder(client: client))
        default:
            throw WalletKitError.internalError(message: "Not implemented yet")
        }
    }
}
