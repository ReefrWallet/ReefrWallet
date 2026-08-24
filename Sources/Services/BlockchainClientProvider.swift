import Foundation
import WalletKit

final class BlockchainClientProvider {
    private var clients: [WKBlockchain: any BlockchainClientProtocol] = [:]

    func getClient(blockchain: WKBlockchain) throws -> any BlockchainClientProtocol {
        if let client = clients[blockchain] { return client }
        let client = try makeClient(blockchain: blockchain)
        clients[blockchain] = client
        return client
    }

    private func makeClient(blockchain: WKBlockchain) throws -> any BlockchainClientProtocol {
        let endpoint = blockchain.rpcURL

        switch blockchain {
        case let .evm(network):
            return EthereumRPCClient(endpoint: endpoint, chainId: network.chainId)
        case .sui:
            guard let host = endpoint.host else {
                throw WalletKitError.invalidAddress(reason: "Invalid Sui endpoint: \(endpoint)")
            }
            return SuiGRPCClient(host: host, port: endpoint.port ?? 443, useTLS: endpoint.scheme == "https")
        default:
            throw WalletKitError.internalError(message: "Not implemented yet")
        }
    }
}
