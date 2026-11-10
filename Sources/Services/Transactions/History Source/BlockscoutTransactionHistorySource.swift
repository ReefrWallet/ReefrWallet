import Alamofire
import Moya
import WalletKit

struct BlockscoutTransactionHistorySource: TransactionHistorySource {
    private static let maxForwardPages = 20

    private let apiBaseURLs: [UInt64: URL]
    private let sessionConfiguration: URLSessionConfiguration

    var providesForwardHistory: Bool {
        true
    }

    init(apiBaseURLs: [UInt64: URL] = [:], sessionConfiguration: URLSessionConfiguration = .default) {
        self.sessionConfiguration = sessionConfiguration
        let defaultAPIBaseURLs = [
            UInt64(1): URL(string: "https://eth.blockscout.com/api/v2")!,
            UInt64(42161): URL(string: "https://arbitrum.blockscout.com/api/v2")!,
            UInt64(421614): URL(string: "https://arbitrum-sepolia.blockscout.com/api/v2")!,
            UInt64(11155111): URL(string: "https://eth-sepolia.blockscout.com/api/v2")!
        ]

        self.apiBaseURLs = defaultAPIBaseURLs.merging(apiBaseURLs) { _, customURL in
            customURL
        }
    }

    func supports(_ account: Account) -> Bool {
        supports(account.blockchain)
    }

    func supports(_ blockchain: Blockchain) -> Bool {
        apiBaseURL(for: blockchain) != nil
    }

    func transactionHistory(
        account: Account,
        request: BlockchainTransactionHistoryRequest
    ) async throws -> BlockchainTransactionPage {
        guard let apiBaseURL = apiBaseURL(for: account.blockchain) else {
            throw URLError(.unsupportedURL)
        }

        if request.direction == .ascending {
            return try await forwardHistory(account: account, apiBaseURL: apiBaseURL, request: request)
        }

        let position = try request.cursor.map(BlockscoutBackfillCursor.init(storedCursor:))
            ?? BlockscoutBackfillCursor()

        async let transactionPage: BlockscoutTransactionsResponse? = position.transactionsFinished
            ? nil
            : provider(for: apiBaseURL).request(
                .transactions(address: account.address, baseURL: apiBaseURL, pagination: position.transactions)
            )

        // The transactions list omits ERC-20 transfers the account didn't initiate, so its
        // token transfers are paged alongside it; otherwise a token received before the first
        // sync would never be discovered.
        async let transferPage: BlockscoutListResponse<BlockscoutTokenTransfer>? = position.tokenTransfersFinished
            ? nil
            : provider(for: apiBaseURL).request(
                .tokenTransfers(address: account.address, baseURL: apiBaseURL, pagination: position.tokenTransfers)
            )

        let transactions = try await transactionPage
        let transfers = try await transferPage
        let next = BlockscoutBackfillCursor(
            transactions: transactions?.nextPageParams,
            transactionsFinished: position.transactionsFinished || transactions?.nextPageParams == nil,
            tokenTransfers: transfers?.nextPageParams,
            tokenTransfersFinished: position.tokenTransfersFinished || transfers?.nextPageParams == nil
        )

        let merged = mergedRecords(transactions: transactions?.items ?? [], transfers: transfers?.items ?? [])
        let reachedBoundary = next.transactionsFinished && next.tokenTransfersFinished

        return BlockchainTransactionPage(
            transactions: merged,
            nextCursor: reachedBoundary ? nil : try JSONEncoder().encode(next),
            reachedBoundary: reachedBoundary,
            head: merged.compactMap(\.blockHeight).max()
        )
    }
}

private extension BlockscoutTransactionHistorySource {
    /// Blockscout only lists newest-first, so a forward (ascending) request pages
    /// down from the tip until it passes `lowerBound`, returning one complete page.
    /// Includes ERC-20 transfers, which the transactions list omits for
    /// transfers the account didn't initiate.
    func forwardHistory(
        account: Account,
        apiBaseURL: URL,
        request: BlockchainTransactionHistoryRequest
    ) async throws -> BlockchainTransactionPage {
        let lowerBound = request.lowerBound ?? 0
        let upperBound = request.upperBound ?? .max

        async let nativeItems: [BlockscoutTransaction] = collectNewest(lowerBound: lowerBound) { pagination in
            .transactions(address: account.address, baseURL: apiBaseURL, pagination: pagination)
        }

        async let tokenItems: [BlockscoutTokenTransfer] = collectNewest(lowerBound: lowerBound) { pagination in
            .tokenTransfers(address: account.address, baseURL: apiBaseURL, pagination: pagination)
        }

        let transactions = try await nativeItems.filter { (lowerBound...upperBound).contains($0.blockNumber) }
        let transfers = try await tokenItems.filter { (lowerBound...upperBound).contains($0.blockNumber) }
        let merged = mergedRecords(transactions: transactions, transfers: transfers)

        return BlockchainTransactionPage(
            transactions: merged,
            nextCursor: nil,
            reachedBoundary: true,
            head: merged.compactMap(\.blockHeight).max()
        )
    }

    /// Joins ERC-20 transfers to the transactions that carry them by hash; a transfer
    /// whose transaction isn't in the list becomes a transaction of its own.
    func mergedRecords(
        transactions: [BlockscoutTransaction],
        transfers: [BlockscoutTokenTransfer]
    ) -> [BlockchainTransaction] {
        var records = Dictionary(
            transactions.map { ($0.hash, $0.blockchainTransaction) },
            uniquingKeysWith: { first, _ in first }
        )

        for (hash, group) in Dictionary(grouping: transfers, by: \.transactionHash) {
            let effects = group.enumerated().map { ordinal, transfer in
                transfer.effect(fallbackIndex: UInt64(ordinal))
            }

            if let transaction = records[hash] {
                records[hash] = BlockchainTransaction(
                    identifier: transaction.identifier,
                    blockHeight: transaction.blockHeight,
                    blockHash: transaction.blockHash,
                    timestamp: transaction.timestamp,
                    transactionIndex: transaction.transactionIndex,
                    sender: transaction.sender,
                    recipient: transaction.recipient,
                    status: transaction.status,
                    rawPayload: transaction.rawPayload,
                    effects: transaction.effects + effects,
                    counterpartyName: transaction.counterpartyName,
                    fee: transaction.fee,
                    method: transaction.method
                )
            } else if let transfer = group.first {
                records[hash] = transfer.blockchainTransaction(effects: effects)
            }
        }

        return records.values.sorted {
            ($0.blockHeight ?? 0, $0.identifier) < ($1.blockHeight ?? 0, $1.identifier)
        }
    }

    /// Pages a newest-first Blockscout list until it reaches items older than `lowerBound`.
    func collectNewest<Item: Decodable & BlockscoutBlockNumbered>(
        lowerBound: UInt64,
        target: (BlockscoutPageParameters?) -> BlockscoutAPI
    ) async throws -> [Item] {
        var items: [Item] = []
        var pagination: BlockscoutPageParameters?

        for _ in 0 ..< Self.maxForwardPages {
            let currentTarget = target(pagination)
            let pageProvider = provider(for: currentTarget.baseURL)
            let response: BlockscoutListResponse<Item> = try await pageProvider.request(currentTarget)
            items.append(contentsOf: response.items)

            guard
                let next = response.nextPageParams,
                let oldest = response.items.map(\.blockNumber).min(),
                oldest >= lowerBound
            else {
                return items
            }

            pagination = next
        }

        throw BlockscoutHistoryError.forwardGapTooLarge
    }

    func apiBaseURL(for blockchain: Blockchain) -> URL? {
        guard case let .evm(chain) = blockchain else {
            return nil
        }

        return apiBaseURLs[chain.chainId]
    }

    /// Blockscout's chains are independently-operated servers — each gets
    /// its own `RateGate` via `RateGateRegistry`'s per-origin keying,
    /// rather than one shared across every chain this source supports.
    func provider(for apiBaseURL: URL) -> MoyaProvider<BlockscoutAPI> {
        RateGateRegistry.shared.makeProvider(
            origin: Self.origin(of: apiBaseURL),
            provider: .blockscout,
            configuration: sessionConfiguration
        )
    }

    static func origin(of url: URL) -> String {
        var components = URLComponents()
        components.scheme = url.scheme
        components.host = url.host
        components.port = url.port
        return components.string ?? url.absoluteString
    }
}

private enum BlockscoutAPI {
    case tokenTransfers(address: String, baseURL: URL, pagination: BlockscoutPageParameters?)
    case transactions(address: String, baseURL: URL, pagination: BlockscoutPageParameters?)
}

private enum BlockscoutHistoryError: LocalizedError {
    case forwardGapTooLarge

    var errorDescription: String? {
        switch self {
        case .forwardGapTooLarge: "Too many new transactions to sync incrementally."
        }
    }
}

private protocol BlockscoutBlockNumbered {
    var blockNumber: UInt64 { get }
}

extension BlockscoutAPI: TargetType {
    var baseURL: URL {
        switch self {
        case let .tokenTransfers(_, baseURL, _), let .transactions(_, baseURL, _):
            baseURL
        }
    }

    var headers: [String: String]? {
        nil
    }

    var method: Moya.Method {
        .get
    }

    var path: String {
        switch self {
        case let .tokenTransfers(address, _, _):
            "addresses/\(address)/token-transfers"
        case let .transactions(address, _, _):
            "addresses/\(address)/transactions"
        }
    }

    var sampleData: Data {
        Data()
    }

    var task: Task {
        switch self {
        case let .tokenTransfers(_, _, pagination):
            .requestParameters(
                parameters: (pagination?.parameters ?? [:]).merging(["type": "ERC-20"]) { current, _ in current },
                encoding: URLEncoding.queryString
            )

        case let .transactions(_, _, pagination):
            pagination.map {
                .requestParameters(parameters: $0.parameters, encoding: URLEncoding.queryString)
            } ?? .requestPlain
        }
    }

    var validationType: ValidationType {
        .successCodes
    }
}

private struct BlockscoutAddress: Codable {
    let hash: String
    let name: String?
}

private struct BlockscoutFee: Codable {
    let value: String?
}

private struct BlockscoutListResponse<Item: Decodable>: Decodable {
    let items: [Item]
    let nextPageParams: BlockscoutPageParameters?

    private enum CodingKeys: String, CodingKey {
        case items, nextPageParams
    }

    /// An item that doesn't decode is dropped, not fatal: Blockscout lists the account's own
    /// pending transactions with a null block number, status and timestamp, and one of those
    /// must not fail the whole page. It is picked up once mined.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let lossy = try container.decode([BlockscoutLossyItem<Item>].self, forKey: .items)
        items = lossy.compactMap(\.value)

        if items.count < lossy.count {
            printDebug("Blockscout: dropped \(lossy.count - items.count) undecodable \(Item.self) item(s)")
        }

        nextPageParams = try container.decodeIfPresent(BlockscoutPageParameters.self, forKey: .nextPageParams)
    }
}

private struct BlockscoutLossyItem<Item: Decodable>: Decodable {
    let value: Item?

    init(from decoder: Decoder) throws {
        value = try? Item(from: decoder)
    }
}

private struct BlockscoutToken: Codable {
    let address: String?
    let addressHash: String?
    let decimals: String?
    let name: String?
    let symbol: String?
}

private struct BlockscoutTokenTotal: Codable {
    let value: String?
}

/// Etherscan-shaped token metadata so `TransactionSyncService` can name the token without an RPC call.
private struct BlockscoutTokenTransferPayload: Codable {
    let contractAddress: String
    let logIndex: UInt64?
    let tokenDecimal: String?
    let tokenName: String?
    let tokenSymbol: String?
    let transactionHash: String
}

private struct BlockscoutTokenTransfer: Codable, BlockscoutBlockNumbered {
    let blockNumber: UInt64
    let from: BlockscoutAddress
    let logIndex: UInt64?
    let timestamp: String?
    let to: BlockscoutAddress
    let token: BlockscoutToken
    let total: BlockscoutTokenTotal?
    let transactionHash: String

    var contractAddress: String {
        let raw = token.addressHash ?? token.address ?? ""
        return (try? EthereumAddress(string: raw).string) ?? raw
    }

    func blockchainTransaction(effects: [BlockchainTransactionEffect]) -> BlockchainTransaction {
        BlockchainTransaction(
            identifier: transactionHash,
            blockHeight: blockNumber,
            timestamp: timestamp.flatMap { ISO8601DateFormatter.blockscout.date(from: $0) },
            sender: from.hash,
            recipient: to.hash,
            status: .confirmed,
            effects: effects,
            counterpartyName: token.name,
            method: "Transfer"
        )
    }

    func effect(fallbackIndex: UInt64) -> BlockchainTransactionEffect {
        BlockchainTransactionEffect(
            index: logIndex ?? fallbackIndex,
            kind: .tokenTransfer,
            assetIdentifier: contractAddress,
            amount: total?.value,
            from: from.hash,
            to: to.hash,
            rawPayload: try? JSONEncoder().encode(
                BlockscoutTokenTransferPayload(
                    contractAddress: contractAddress,
                    logIndex: logIndex,
                    tokenDecimal: token.decimals,
                    tokenName: token.name,
                    tokenSymbol: token.symbol,
                    transactionHash: transactionHash
                )
            )
        )
    }
}

private struct BlockscoutTransaction: Codable, BlockscoutBlockNumbered {
    let blockNumber: UInt64
    let fee: BlockscoutFee?
    let from: BlockscoutAddress
    let hash: String
    let method: String?
    let status: String?
    let timestamp: String
    let to: BlockscoutAddress?
    let value: String

    var blockchainTransaction: BlockchainTransaction {
        BlockchainTransaction(
            identifier: hash,
            blockHeight: blockNumber,
            timestamp: ISO8601DateFormatter.blockscout.date(from: timestamp),
            sender: from.hash,
            recipient: to?.hash,
            status: status == "error" ? .failed : .confirmed,
            rawPayload: try? JSONEncoder().encode(self),
            effects: nativeTransferEffect.map { [$0] } ?? [],
            counterpartyName: to?.name,
            fee: fee?.value,
            method: EVMMethodName.display(method, hasValue: nativeTransferEffect != nil)
        )
    }

    private var nativeTransferEffect: BlockchainTransactionEffect? {
        guard let amount = BigUInt(value), amount > 0 else {
            return nil
        }

        return BlockchainTransactionEffect(
            index: 0,
            kind: .nativeTransfer,
            amount: amount.description,
            from: from.hash,
            to: to?.hash
        )
    }
}

private typealias BlockscoutTransactionsResponse = BlockscoutListResponse<BlockscoutTransaction>

private extension ISO8601DateFormatter {
    static let blockscout: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
