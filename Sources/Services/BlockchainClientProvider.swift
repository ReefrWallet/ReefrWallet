import WalletKit

/// Creates WalletKit blockchain clients and transaction builders.
///
/// Holds no state: every call returns a newly created instance configured
/// for the requested ``Blockchain``, RPC override and Bitcoin backend.
/// Creating one is cheap — WalletKit pools the expensive parts (Bitcoin's
/// Electrum connection and address discovery, Sui's gRPC connection) per
/// endpoint.
struct BlockchainClientProvider: Sendable {
    /// Creates a client for `blockchain`.
    ///
    /// - Parameter backend: Which indexing backend a Bitcoin account uses
    ///   (see ``Account/bitcoinBackend``). Ignored for every other chain.
    /// - Throws: ``WalletKitError`` if the blockchain's endpoint URL is
    ///   invalid.
    func makeClient(
        blockchain: Blockchain,
        rpcURL: URL? = nil,
        backend: BitcoinBackendKind? = nil
    ) throws -> any BlockchainClientProtocol {
        switch blockchain {
        case .aptos:
            return try aptosClient(blockchain: blockchain, rpcURL: rpcURL)
        case let .evm(chain):
            let endpoint = rpcURL ?? blockchain.rpcURL
            return EthereumRPCClient(endpoint: endpoint, chainId: chain.chainId)
        case .sui:
            return try makeSuiClient(endpoint: rpcURL ?? blockchain.rpcURL)
        case let .bitcoin(network):
            return try makeBitcoinClient(network: network, rpcURL: rpcURL, backend: backend)
        case .cardano:
            let endpoint = rpcURL ?? blockchain.rpcURL
            return CardanoClient(endpoint: endpoint, projectId: blockfrostProjectId(for: blockchain))
        case .tron:
            return try tronClient(blockchain: blockchain, rpcURL: rpcURL)
        case .solana:
            let endpoint = rpcURL ?? blockchain.rpcURL
            return SolanaRPCClient(endpoint: endpoint)
        }
    }

    /// Creates a transaction builder for `blockchain`, backed by a new
    /// client.
    ///
    /// - Parameter backend: Which indexing backend a Bitcoin account uses
    ///   (see ``Account/bitcoinBackend``). Ignored for every other chain.
    /// - Throws: ``WalletKitError`` if the blockchain's endpoint URL is
    ///   invalid.
    func makeTransactionBuilder(
        blockchain: Blockchain,
        rpcURL: URL? = nil,
        backend: BitcoinBackendKind? = nil
    ) throws -> any BlockchainTransactionBuilderProtocol {
        switch blockchain {
        case .aptos:
            return try AptosTransactionBuilder(client: aptosClient(blockchain: blockchain, rpcURL: rpcURL))
        case let .evm(chain):
            let endpoint = rpcURL ?? blockchain.rpcURL
            return EthereumTransactionBuilder(client: EthereumRPCClient(endpoint: endpoint, chainId: chain.chainId))
        case .sui:
            return try SuiTransactionBuilder(client: makeSuiClient(endpoint: rpcURL ?? blockchain.rpcURL))
        case let .bitcoin(network):
            let client = try makeBitcoinClient(network: network, rpcURL: rpcURL, backend: backend)
            return BitcoinTransactionBuilder(client: client)
        case .cardano:
            let endpoint = rpcURL ?? blockchain.rpcURL
            let client = CardanoClient(endpoint: endpoint, projectId: blockfrostProjectId(for: blockchain))
            return CardanoTransactionBuilder(client: client)
        case .tron:
            let endpoint = rpcURL ?? blockchain.rpcURL
            let client = TronClient(endpoint: endpoint, apiKey: tronGridAPIKey(for: blockchain))
            return TronTransactionBuilder(client: client)
        case .solana:
            let endpoint = rpcURL ?? blockchain.rpcURL
            return SolanaTransactionBuilder(client: SolanaRPCClient(endpoint: endpoint))
        }
    }

    /// Resolves the concrete ``AptosClient`` for `account`'s Aptos network,
    /// honoring its RPC override.
    ///
    /// - Throws: ``Error/invalidData`` if `account` isn't on Aptos.
    func aptosClient(for account: Account) throws -> AptosClient {
        try aptosClient(blockchain: account.blockchain, rpcURL: account.rpcURLOverride)
    }

    /// Resolves the concrete ``AptosClient`` for Aptos. An RPC override keeps
    /// the indexer only when it points at Aptos Labs; a custom node has none.
    func aptosClient(blockchain: Blockchain, rpcURL: URL? = nil) throws -> AptosClient {
        guard case let .aptos(network) = blockchain else {
            throw Error.invalidData
        }

        let indexerURL: URL? = if let rpcURL {
            Self.isHost(rpcURL.host, within: "aptoslabs.com") ? rpcURL.appending(path: "graphql") : nil
        } else {
            network.indexerURL
        }

        return AptosClient(endpoint: rpcURL ?? network.rpcURL, indexerURL: indexerURL, apiKey: aptosAPIKey())
    }

    /// Whether `host` is `domain` itself or one of its subdomains.
    ///
    /// A bare `hasSuffix(domain)` would also match `notaptoslabs.com`, which
    /// an attacker can register — and this decides whether the user's API key
    /// is sent to that host, so the dot boundary matters.
    static func isHost(_ host: String?, within domain: String) -> Bool {
        guard let host = host?.lowercased() else {
            return false
        }

        return host == domain || host.hasSuffix(".\(domain)")
    }

    private func aptosAPIKey() -> String? {
        let setting = UserDefaults.standard
            .string(forKey: "AptosAPIKey")?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let setting, !setting.isEmpty {
            return setting
        }

        return ProcessInfo.processInfo
            .environment["APTOS_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func makeSuiClient(endpoint: URL) throws -> SuiGRPCClient {
        guard let host = endpoint.host else {
            throw WalletKitError.invalidAddress(reason: "Invalid Sui endpoint: \(endpoint)")
        }

        return SuiGRPCClient(host: host, port: endpoint.port ?? 443, useTLS: endpoint.scheme == "https")
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

            return BitcoinClient(electrumHost: host, port: port, useTLS: useTLS, network: network)
        case .esplora:
            return BitcoinClient(esploraEndpoint: endpoint, network: network)
        }
    }

    /// Resolves the concrete ``BitcoinClient`` for `account`'s Bitcoin
    /// network, honoring its RPC override and backend.
    ///
    /// - Throws: ``Error/invalidData`` if `account` isn't on Bitcoin.
    func bitcoinClient(for account: Account) throws -> BitcoinClient {
        guard case let .bitcoin(network) = account.blockchain else {
            throw Error.invalidData
        }

        return try makeBitcoinClient(network: network, rpcURL: account.rpcURLOverride, backend: account.bitcoinBackend)
    }

    /// Resolves the concrete ``EthereumRPCClient`` for `account`'s EVM
    /// chain, honoring its RPC override — the chain-specific client a
    /// dapp provider needs (`buildCall`, `request(method:params:)`) that
    /// ``BlockchainClientProtocol`` doesn't expose.
    ///
    /// - Throws: ``Error/invalidData`` if `account` isn't on an EVM chain.
    func ethereumClient(for account: Account) throws -> EthereumRPCClient {
        try ethereumClient(blockchain: account.blockchain, rpcURL: account.rpcURLOverride)
    }

    /// Resolves the concrete ``EthereumRPCClient`` for an EVM blockchain,
    /// honoring an optional RPC override.
    func ethereumClient(blockchain: Blockchain, rpcURL: URL? = nil) throws -> EthereumRPCClient {
        guard case let .evm(chain) = blockchain else {
            throw Error.invalidData
        }

        return EthereumRPCClient(endpoint: rpcURL ?? blockchain.rpcURL, chainId: chain.chainId)
    }

    /// Resolves the concrete ``SuiGRPCClient`` for `account`'s Sui
    /// network, honoring its RPC override — the chain-specific client a
    /// dapp provider needs (`executeTransactionWithEffects`) that
    /// ``BlockchainClientProtocol`` doesn't expose.
    ///
    /// - Throws: ``Error/invalidData`` if `account` isn't on Sui, or
    ///   ``WalletKitError/invalidAddress(reason:)`` if the endpoint has
    ///   no host.
    func suiClient(for account: Account) throws -> SuiGRPCClient {
        try suiClient(blockchain: account.blockchain, rpcURL: account.rpcURLOverride)
    }

    /// Resolves the concrete ``SuiGRPCClient`` for Sui, honoring an optional
    /// RPC override.
    func suiClient(blockchain: Blockchain, rpcURL: URL? = nil) throws -> SuiGRPCClient {
        guard case .sui = blockchain else {
            throw Error.invalidData
        }

        return try makeSuiClient(endpoint: rpcURL ?? blockchain.rpcURL)
    }

    /// Resolves the concrete ``SolanaRPCClient`` for `account`'s Solana
    /// network, honoring its RPC override — the chain-specific client a
    /// dapp provider needs (`sendTransaction(_:options:)`) that
    /// ``BlockchainClientProtocol`` doesn't expose.
    ///
    /// - Throws: ``Error/invalidData`` if `account` isn't on Solana.
    func solanaClient(for account: Account) throws -> SolanaRPCClient {
        guard case .solana = account.blockchain else {
            throw Error.invalidData
        }

        let endpoint = account.rpcURLOverride ?? account.blockchain.rpcURL
        return SolanaRPCClient(endpoint: endpoint)
    }

    /// A ``TronClient`` for `account`'s network, honoring its RPC override
    /// and the configured TronGrid API key.
    ///
    /// - Throws: ``Error/invalidData`` if `account` isn't on Tron.
    func tronClient(for account: Account) throws -> TronClient {
        try tronClient(blockchain: account.blockchain, rpcURL: account.rpcURLOverride)
    }

    /// A ``TronClient`` for `blockchain`, honoring `rpcURL` and the
    /// configured TronGrid API key.
    ///
    /// - Throws: ``Error/invalidData`` if `blockchain` isn't Tron.
    func tronClient(blockchain: Blockchain, rpcURL: URL? = nil) throws -> TronClient {
        guard case let .tron(network) = blockchain else {
            throw Error.invalidData
        }

        // A custom node opts out of third-party indexers.
        return TronClient(
            endpoint: rpcURL ?? blockchain.rpcURL,
            apiKey: tronGridAPIKey(for: blockchain),
            tronScanEndpoint: rpcURL == nil ? network.tronScanURL : nil,
            tronScanAPIKey: apiKey(setting: "TronScanAPIKey", environmentKey: "TRONSCAN_API_KEY")
        )
    }

    private func apiKey(setting key: String, environmentKey: String) -> String? {
        let setting = UserDefaults.standard
            .string(forKey: key)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let setting, !setting.isEmpty {
            return setting
        }

        return ProcessInfo.processInfo
            .environment[environmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func blockfrostProjectId(for blockchain: Blockchain) -> String? {
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

        let setting = UserDefaults.standard
            .string(forKey: key)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let setting, !setting.isEmpty {
            return setting
        }

        return ProcessInfo.processInfo
            .environment[environmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func tronGridAPIKey(for blockchain: Blockchain) -> String? {
        guard case .tron = blockchain else {
            return nil
        }

        return apiKey(setting: "TronGridAPIKey", environmentKey: "TRONGRID_API_KEY")
    }
}
