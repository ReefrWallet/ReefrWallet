import Foundation
import WalletKit

/// Caches and vends ``AnyBlockchainClient`` instances, one per
/// ``WKBlockchain``. ``BlockchainClientProtocol`` has `associatedtype
/// Address`, making it a PAT that cannot be used directly as an existential
/// (`any BlockchainClientProtocol`). ``AnyBlockchainClient`` is the
/// String-based type-eraser that consumers such as `BalancesService` use
/// instead — they get all the same methods, with plain `String` owner
/// parameters, without knowing the concrete chain type.
final class BlockchainClientProvider {
    private var clients: [WKBlockchain: AnyBlockchainClient] = [:]

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
}
