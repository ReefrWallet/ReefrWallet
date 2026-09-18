import Foundation
import WalletKit

/// Caches and vends ``AnyBlockchainClient`` and
/// ``AnyBlockchainTransactionBuilder`` instances, one per ``WKBlockchain``.
actor BlockchainClientProvider {
    private struct Target: Hashable {
        let blockchain: WKBlockchain
        let rpcURL: URL?
    }

    private var clients: [Target: AnyBlockchainClient] = [:]
    private var builders: [Target: AnyBlockchainTransactionBuilder] = [:]

    /// Returns the cached ``AnyBlockchainClient`` for `blockchain`, creating
    /// one on the first call.
    ///
    /// - Throws: ``WalletKitError`` if the blockchain's endpoint URL is
    ///   invalid or the blockchain is not yet supported.
    func getClient(blockchain: WKBlockchain, rpcURL: URL? = nil) throws -> AnyBlockchainClient {
        let target = Target(blockchain: blockchain, rpcURL: rpcURL)
        if let client = clients[target] { return client }
        let client = try makeClient(blockchain: blockchain, rpcURL: rpcURL)
        clients[target] = client
        return client
    }

    /// Returns the cached ``AnyBlockchainTransactionBuilder`` for `blockchain`,
    /// creating one on the first call.
    ///
    /// - Throws: ``WalletKitError`` if the blockchain's endpoint URL is
    ///   invalid or the blockchain is not yet supported.
    func getBuilder(blockchain: WKBlockchain, rpcURL: URL? = nil) throws -> AnyBlockchainTransactionBuilder {
        let target = Target(blockchain: blockchain, rpcURL: rpcURL)
        if let builder = builders[target] { return builder }
        let builder = try makeBuilder(blockchain: blockchain, rpcURL: rpcURL)
        builders[target] = builder
        return builder
    }

    private func makeClient(blockchain: WKBlockchain, rpcURL: URL?) throws -> AnyBlockchainClient {
        let endpoint = rpcURL ?? blockchain.rpcURL

        switch blockchain {
        case let .evm(chain):
            return AnyBlockchainClient(EthereumRPCClient(endpoint: endpoint, chainId: chain.chainId))
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

    private func makeBuilder(blockchain: WKBlockchain, rpcURL: URL?) throws -> AnyBlockchainTransactionBuilder {
        let endpoint = rpcURL ?? blockchain.rpcURL

        switch blockchain {
        case let .evm(chain):
            let client = EthereumRPCClient(endpoint: endpoint, chainId: chain.chainId)
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
