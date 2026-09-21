import Foundation
import WalletKit

/// Caches and vends ``AnyBlockchainClient`` and
/// ``AnyBlockchainTransactionBuilder`` instances, one per ``WKBlockchain``.
actor BlockchainClientProvider {
    private struct Target: Hashable {
        let blockchain: WKBlockchain
        let rpcURL: URL?
        let backend: BitcoinBackendKind?
        let blockfrostProjectID: String?
        let tronGridAPIKey: String?
    }

    private var clients: [Target: AnyBlockchainClient] = [:]
    private var builders: [Target: AnyBlockchainTransactionBuilder] = [:]

    /// Returns the cached ``AnyBlockchainClient`` for `blockchain`, creating
    /// one on the first call.
    ///
    /// - Parameter backend: Which indexing backend a Bitcoin account uses
    ///   (see ``Account/bitcoinBackend``). Ignored for every other chain.
    /// - Throws: ``WalletKitError`` if the blockchain's endpoint URL is
    ///   invalid or the blockchain is not yet supported.
    func getClient(
        blockchain: WKBlockchain,
        rpcURL: URL? = nil,
        backend: BitcoinBackendKind? = nil
    ) throws -> AnyBlockchainClient {
        let blockfrostProjectID = blockfrostProjectID(for: blockchain)
        let tronGridAPIKey = tronGridAPIKey(for: blockchain)
        let target = Target(
            blockchain: blockchain,
            rpcURL: rpcURL,
            backend: backend,
            blockfrostProjectID: blockfrostProjectID,
            tronGridAPIKey: tronGridAPIKey
        )
        if let client = clients[target] { return client }
        let client = try makeClient(
            blockchain: blockchain,
            rpcURL: rpcURL,
            backend: backend,
            blockfrostProjectID: blockfrostProjectID,
            tronGridAPIKey: tronGridAPIKey
        )
        clients[target] = client
        return client
    }

    /// Returns the cached ``AnyBlockchainTransactionBuilder`` for `blockchain`,
    /// creating one on the first call.
    ///
    /// - Parameter backend: Which indexing backend a Bitcoin account uses
    ///   (see ``Account/bitcoinBackend``). Ignored for every other chain.
    /// - Throws: ``WalletKitError`` if the blockchain's endpoint URL is
    ///   invalid or the blockchain is not yet supported.
    func getBuilder(
        blockchain: WKBlockchain,
        rpcURL: URL? = nil,
        backend: BitcoinBackendKind? = nil
    ) throws -> AnyBlockchainTransactionBuilder {
        let blockfrostProjectID = blockfrostProjectID(for: blockchain)
        let tronGridAPIKey = tronGridAPIKey(for: blockchain)
        let target = Target(
            blockchain: blockchain,
            rpcURL: rpcURL,
            backend: backend,
            blockfrostProjectID: blockfrostProjectID,
            tronGridAPIKey: tronGridAPIKey
        )
        if let builder = builders[target] { return builder }
        let builder = try makeBuilder(
            blockchain: blockchain,
            rpcURL: rpcURL,
            backend: backend,
            blockfrostProjectID: blockfrostProjectID,
            tronGridAPIKey: tronGridAPIKey
        )
        builders[target] = builder
        return builder
    }

    private func makeClient(
        blockchain: WKBlockchain,
        rpcURL: URL?,
        backend: BitcoinBackendKind?,
        blockfrostProjectID: String?,
        tronGridAPIKey: String?
    ) throws -> AnyBlockchainClient {
        switch blockchain {
        case let .evm(chain):
            let endpoint = rpcURL ?? blockchain.rpcURL
            return AnyBlockchainClient(EthereumRPCClient(endpoint: endpoint, chainId: chain.chainId))
        case .sui:
            let endpoint = rpcURL ?? blockchain.rpcURL
            guard let host = endpoint.host else {
                throw WalletKitError.invalidAddress(reason: "Invalid Sui endpoint: \(endpoint)")
            }
            return AnyBlockchainClient(
                SuiGRPCClient(host: host, port: endpoint.port ?? 443, useTLS: endpoint.scheme == "https")
            )
        case let .bitcoin(network):
            return AnyBlockchainClient(try makeBitcoinClient(network: network, rpcURL: rpcURL, backend: backend))
        case .cardano:
            let endpoint = rpcURL ?? blockchain.rpcURL
            return AnyBlockchainClient(CardanoClient(endpoint: endpoint, projectID: blockfrostProjectID))
        case .tron:
            let endpoint = rpcURL ?? blockchain.rpcURL
            return AnyBlockchainClient(TronClient(endpoint: endpoint, apiKey: tronGridAPIKey))
        case .solana:
            let endpoint = rpcURL ?? blockchain.rpcURL
            return AnyBlockchainClient(SolanaRPCClient(endpoint: endpoint))
        }
    }

    private func makeBuilder(
        blockchain: WKBlockchain,
        rpcURL: URL?,
        backend: BitcoinBackendKind?,
        blockfrostProjectID: String?,
        tronGridAPIKey: String?
    ) throws -> AnyBlockchainTransactionBuilder {
        switch blockchain {
        case let .evm(chain):
            let endpoint = rpcURL ?? blockchain.rpcURL
            let client = EthereumRPCClient(endpoint: endpoint, chainId: chain.chainId)
            return AnyBlockchainTransactionBuilder(EthereumTransactionBuilder(client: client))
        case .sui:
            let endpoint = rpcURL ?? blockchain.rpcURL
            guard let host = endpoint.host else {
                throw WalletKitError.invalidAddress(reason: "Invalid Sui endpoint: \(endpoint)")
            }
            let client = SuiGRPCClient(
                host: host, port: endpoint.port ?? 443, useTLS: endpoint.scheme == "https"
            )
            return AnyBlockchainTransactionBuilder(SuiTransactionBuilder(client: client))
        case let .bitcoin(network):
            let client = try makeBitcoinClient(network: network, rpcURL: rpcURL, backend: backend)
            return AnyBlockchainTransactionBuilder(BitcoinTransactionBuilder(client: client))
        case .cardano:
            let endpoint = rpcURL ?? blockchain.rpcURL
            let client = CardanoClient(endpoint: endpoint, projectID: blockfrostProjectID)
            return AnyBlockchainTransactionBuilder(CardanoTransactionBuilder(client: client))
        case .tron:
            let endpoint = rpcURL ?? blockchain.rpcURL
            let client = TronClient(endpoint: endpoint, apiKey: tronGridAPIKey)
            return AnyBlockchainTransactionBuilder(TronTransactionBuilder(client: client))
        case .solana:
            let endpoint = rpcURL ?? blockchain.rpcURL
            let client = SolanaRPCClient(endpoint: endpoint)
            return AnyBlockchainTransactionBuilder(SolanaTransactionBuilder(client: client))
        }
    }

    private func makeBitcoinClient(
        network: BitcoinNetwork,
        rpcURL: URL?,
        backend: BitcoinBackendKind?
    ) throws -> BitcoinClient {
        let effectiveBackend = backend ?? .electrum
        let endpoint = rpcURL ?? network.defaultEndpoint(for: effectiveBackend)

        switch effectiveBackend {
        case .electrum:
            guard let host = endpoint.host else {
                throw WalletKitError.invalidAddress(reason: "Invalid Electrum endpoint: \(endpoint)")
            }
            let useTLS = endpoint.scheme != "tcp"
            let port = UInt16(endpoint.port ?? (useTLS ? 50002 : 50001))
            return BitcoinClient(electrumHost: host, port: port, useTLS: useTLS)
        case .esplora:
            return BitcoinClient(esploraEndpoint: endpoint)
        }
    }

    private func blockfrostProjectID(for blockchain: WKBlockchain) -> String? {
        let key: String
        let environmentKey: String
        switch blockchain {
        case let .cardano(network):
            switch network {
            case .mainnet:
                key = "BlockfrostMainnetProjectID"
                environmentKey = "BLOCKFROST_MAINNET_PROJECT_ID"
            case .preprod:
                key = "BlockfrostPreprodProjectID"
                environmentKey = "BLOCKFROST_PREPROD_PROJECT_ID"
            }
        default:
            return nil
        }

        let setting = UserDefaults.standard.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let setting, !setting.isEmpty {
            return setting
        }
        return ProcessInfo.processInfo.environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func tronGridAPIKey(for blockchain: WKBlockchain) -> String? {
        guard case .tron = blockchain else {
            return nil
        }

        return UserDefaults.standard.string(forKey: "TronGridAPIKey")
    }
}
