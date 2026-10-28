import Alamofire
import Moya
import WalletKit

struct EtherscanTransactionHistorySource: TransactionHistorySource {
    static let apiKeyDefaultsKey = "EtherscanAPIKey"

    /// Open upper bound; must exceed every chain tip (Arbitrum is past 500M).
    private static let maxBlock = UInt64(Int64.max)

    /// Scheme + host only (no path) — matches `RateGateRegistry`'s
    /// per-origin keying, not the API's full base URL.
    private static let origin = "https://api.etherscan.io"

    private let baseURL = URL(string: "https://api.etherscan.io/v2/api")!
    private let provider: MoyaProvider<EtherscanAPI>
    private let supportedChainIds: Set<UInt64> = [1, 56, 97, 42161, 421614, 11155111]
    private let userDefaults: UserDefaults

    var providesForwardHistory: Bool {
        true
    }

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults

        let policy = RateGateRegistry.shared.makeRetryPolicy(for: Self.origin, provider: .etherscan)
        provider = MoyaProvider<EtherscanAPI>(session: Session(interceptor: policy))
    }

    func supports(_ account: Account) -> Bool {
        supports(account.blockchain)
    }

    func supports(_ blockchain: Blockchain) -> Bool {
        guard case let .evm(chain) = blockchain else {
            return false
        }

        return supportedChainIds.contains(chain.chainId) && !apiKey.isEmpty
    }

    func transactionHistory( // swiftlint:disable:this function_body_length
        account: Account,
        request: BlockchainTransactionHistoryRequest
    ) async throws -> BlockchainTransactionPage {
        guard case let .evm(chain) = account.blockchain, supportedChainIds.contains(chain.chainId) else {
            throw URLError(.unsupportedURL)
        }

        guard !apiKey.isEmpty else {
            throw EtherscanAPIError.missingAPIKey
        }

        let cursor = try request.cursor.map {
            try JSONDecoder().decode(EtherscanCursor.self, from: $0)
        } ?? EtherscanCursor(
            direction: request.direction,
            lowerBound: request.lowerBound ?? 0,
            upperBound: request.upperBound ?? Self.maxBlock,
            tokens: EtherscanListCursor(
                boundary: request.direction == .descending
                    ? request.upperBound ?? Self.maxBlock
                    : request.lowerBound ?? 0,
                page: 1
            ),
            transactions: EtherscanListCursor(
                boundary: request.direction == .descending
                    ? request.upperBound ?? Self.maxBlock
                    : request.lowerBound ?? 0,
                page: 1
            )
        )

        let offset = min(Int(request.limit), 100)

        async let tokenResponse = history(
            action: "tokentx",
            address: account.address,
            apiKey: apiKey,
            chainId: chain.chainId,
            cursor: cursor.tokens,
            direction: cursor.direction,
            lowerBound: cursor.lowerBound,
            offset: offset,
            upperBound: cursor.upperBound
        ) as EtherscanResponse<EtherscanTokenTransfer>

        async let transactionResponse = history(
            action: "txlist",
            address: account.address,
            apiKey: apiKey,
            chainId: chain.chainId,
            cursor: cursor.transactions,
            direction: cursor.direction,
            lowerBound: cursor.lowerBound,
            offset: offset,
            upperBound: cursor.upperBound
        ) as EtherscanResponse<EtherscanTransaction>

        let tokenTransfers = try await tokenResponse.result
        let transactions = try await transactionResponse.result
        let nextCursor = EtherscanCursor(
            direction: cursor.direction,
            lowerBound: cursor.lowerBound,
            upperBound: cursor.upperBound,
            tokens: nextCursor(
                for: cursor.tokens,
                direction: cursor.direction,
                items: tokenTransfers,
                offset: offset
            ),
            transactions: nextCursor(
                for: cursor.transactions,
                direction: cursor.direction,
                items: transactions,
                offset: offset
            )
        )

        let mergedTransactions = merge(transactions: transactions, tokenTransfers: tokenTransfers)
        let reachedBoundary = nextCursor.tokens == nil && nextCursor.transactions == nil

        return BlockchainTransactionPage(
            transactions: mergedTransactions,
            nextCursor: reachedBoundary ? nil : try JSONEncoder().encode(nextCursor),
            reachedBoundary: reachedBoundary,
            head: mergedTransactions.compactMap(\.blockHeight).max()
        )
    }
}

private extension EtherscanTransactionHistorySource {
    var apiKey: String {
        userDefaults
            .string(forKey: Self.apiKeyDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        ?? ""
    }

    func history<T>(
        action: String,
        address: String,
        apiKey: String,
        chainId: UInt64,
        cursor: EtherscanListCursor?,
        direction: BlockchainTransactionScanDirection,
        lowerBound: UInt64,
        offset: Int,
        upperBound: UInt64
    ) async throws -> EtherscanResponse<T> where T: Decodable {
        guard let cursor else {
            return EtherscanResponse(result: [])
        }

        let endBlock = direction == .descending ? cursor.boundary : upperBound
        let startBlock = direction == .descending ? lowerBound : cursor.boundary
        let target = EtherscanAPI.history(
            action: action,
            address: address,
            apiKey: apiKey,
            chainId: chainId,
            endBlock: endBlock,
            page: cursor.page,
            offset: offset,
            sort: direction == .descending ? "desc" : "asc",
            startBlock: startBlock
        )

        for attempt in 0..<3 {
            do {
                return try await provider.request(target)
            } catch EtherscanAPIError.rateLimited where attempt < 2 {
                // In-band (HTTP 200), invisible to the interceptor — push
                // the shared gate directly (ADR-026). No sleep needed: the
                // retry below re-enters `adapt`, which waits it out.
                await RateGateRegistry.shared.penalize(
                    origin: Self.origin,
                    provider: .etherscan,
                    by: .seconds(RateLimitRetryPolicy.backoffSeconds(attempt: attempt))
                )
            }
        }

        return try await provider.request(target)
    }

    func merge(
        transactions: [EtherscanTransaction],
        tokenTransfers: [EtherscanTokenTransfer]
    ) -> [BlockchainTransaction] {
        var records = Dictionary(
            uniqueKeysWithValues: transactions.map { ($0.hash, $0.blockchainTransaction) }
        )

        let tokenTransfersByHash = Dictionary(grouping: tokenTransfers, by: \.hash)

        for (hash, transfers) in tokenTransfersByHash {
            let sortedTransfers = transfers.sorted(by: EtherscanTokenTransfer.stableOrder)
            let effects = sortedTransfers.enumerated().map { ordinal, transfer in
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
            } else if let transfer = sortedTransfers.first {
                records[hash] = transfer.blockchainTransaction(effects: effects)
            }
        }

        return records.values.sorted {
            ($0.blockHeight ?? 0, $0.identifier) > ($1.blockHeight ?? 0, $1.identifier)
        }
    }

    func nextCursor<Item>(
        for cursor: EtherscanListCursor?,
        direction: BlockchainTransactionScanDirection,
        items: [Item],
        offset: Int
    ) -> EtherscanListCursor? where Item: EtherscanBlockNumbered {
        guard let cursor else {
            return nil
        }

        guard items.count == offset else {
            return nil
        }

        guard (cursor.page + 1) * offset > 10_000 else {
            return EtherscanListCursor(boundary: cursor.boundary, page: cursor.page + 1)
        }

        let boundary = direction == .descending
            ? items.compactMap(\.numericBlockNumber).min()
            : items.compactMap(\.numericBlockNumber).max()

        guard let boundary, boundary != cursor.boundary else {
            return EtherscanListCursor(boundary: cursor.boundary, page: cursor.page + 1)
        }

        return EtherscanListCursor(boundary: boundary, page: 1)
    }
}

private enum EtherscanAPI {
    case history(
        action: String,
        address: String,
        apiKey: String,
        chainId: UInt64,
        endBlock: UInt64,
        page: Int,
        offset: Int,
        sort: String,
        startBlock: UInt64
    )
}

extension EtherscanAPI: TargetType {
    var baseURL: URL {
        URL(string: "https://api.etherscan.io/v2/api")!
    }

    var headers: [String: String]? {
        nil
    }

    var method: Moya.Method {
        .get
    }

    var path: String {
        ""
    }

    var sampleData: Data {
        Data()
    }

    var task: Task {
        switch self {
        case let .history(action, address, apiKey, chainId, endBlock, page, offset, sort, startBlock):
            .requestParameters(
                parameters: [
                    "action": action,
                    "address": address,
                    "apikey": apiKey,
                    "chainid": chainId,
                    "endblock": endBlock,
                    "module": "account",
                    "offset": offset,
                    "page": page,
                    "sort": sort,
                    "startblock": startBlock
                ],
                encoding: URLEncoding.queryString
            )
        }
    }

    var validationType: ValidationType {
        .successCodes
    }
}

private struct EtherscanCursor: Codable {
    let direction: BlockchainTransactionScanDirection
    let lowerBound: UInt64
    let upperBound: UInt64
    let tokens: EtherscanListCursor?
    let transactions: EtherscanListCursor?
}

private struct EtherscanListCursor: Codable {
    let boundary: UInt64
    let page: Int
}

private protocol EtherscanBlockNumbered {
    var numericBlockNumber: UInt64? { get }
}

private enum EtherscanAPIError: LocalizedError {
    case message(String)
    case missingAPIKey
    case rateLimited(String)

    var errorDescription: String? {
        switch self {
        case let .message(message), let .rateLimited(message):
            String(localized: .etherscanError(message))
        case .missingAPIKey:
            String(localized: .etherscanKeyRequired)
        }
    }
}

private struct EtherscanResponse<Result: Decodable>: Decodable {
    let result: [Result]

    init(result: [Result]) {
        self.result = result
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let message = try container.decodeIfPresent(String.self, forKey: .message) ?? "Unknown API error"

        if let result = try? container.decode([Result].self, forKey: .result) {
            self.result = result
            return
        }

        let result = try container.decodeIfPresent(String.self, forKey: .result) ?? message

        if message == "No transactions found" {
            self.result = []
        } else if result.localizedCaseInsensitiveContains("rate limit") {
            throw EtherscanAPIError.rateLimited(result)
        } else {
            throw EtherscanAPIError.message(result)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case message
        case result
    }
}

private struct EtherscanTokenTransfer: Codable, EtherscanBlockNumbered {
    let blockNumber: EtherscanString
    let contractAddress: String
    let from: String
    let hash: String
    let logIndex: EtherscanString?
    let timeStamp: String
    let tokenDecimal: EtherscanString?
    let tokenName: String?
    let tokenSymbol: String?
    let to: String
    let value: String

    func blockchainTransaction(effects: [BlockchainTransactionEffect]) -> BlockchainTransaction {
        BlockchainTransaction(
            identifier: hash,
            blockHeight: numericBlockNumber,
            timestamp: timestamp,
            sender: from,
            recipient: to,
            status: .confirmed,
            rawPayload: try? JSONEncoder().encode(self),
            effects: effects,
            counterpartyName: tokenName,
            method: "Transfer"
        )
    }

    func effect(fallbackIndex: UInt64) -> BlockchainTransactionEffect {
        BlockchainTransactionEffect(
            index: UInt64(logIndex?.value ?? "") ?? fallbackIndex,
            kind: .tokenTransfer,
            assetIdentifier: (try? EthereumAddress(string: contractAddress).string) ?? contractAddress,
            amount: value,
            from: from,
            to: to,
            rawPayload: try? JSONEncoder().encode(self)
        )
    }

    static func stableOrder(lhs: EtherscanTokenTransfer, rhs: EtherscanTokenTransfer) -> Bool {
        (lhs.contractAddress, lhs.from, lhs.to, lhs.value) < (rhs.contractAddress, rhs.from, rhs.to, rhs.value)
    }

    var numericBlockNumber: UInt64? {
        UInt64(blockNumber.value)
    }

    private var timestamp: Date? {
        TimeInterval(timeStamp).map(Date.init(timeIntervalSince1970:))
    }
}

private struct EtherscanTransaction: Codable, EtherscanBlockNumbered {
    let blockNumber: EtherscanString
    let from: String
    let functionName: String?
    let gasPrice: String?
    let gasUsed: String?
    let hash: String
    let isError: String
    let timeStamp: String
    let to: String?
    let value: String

    var blockchainTransaction: BlockchainTransaction {
        BlockchainTransaction(
            identifier: hash,
            blockHeight: numericBlockNumber,
            timestamp: timestamp,
            sender: from,
            recipient: to,
            status: isError == "1" ? .failed : .confirmed,
            rawPayload: try? JSONEncoder().encode(self),
            effects: nativeTransferEffect.map { [$0] } ?? [],
            fee: fee,
            method: EVMMethodName.display(functionName, hasValue: nativeTransferEffect != nil)
        )
    }

    private var fee: String? {
        guard let gasUsed = gasUsed.flatMap({ BigUInt($0) }), let gasPrice = gasPrice.flatMap({ BigUInt($0) }) else {
            return nil
        }

        return (gasUsed * gasPrice).description
    }

    private var nativeTransferEffect: BlockchainTransactionEffect? {
        guard let amount = BigUInt(value), amount > 0 else {
            return nil
        }

        return BlockchainTransactionEffect(
            index: 0,
            kind: .nativeTransfer,
            amount: amount.description,
            from: from,
            to: to
        )
    }

    private var timestamp: Date? {
        TimeInterval(timeStamp).map(Date.init(timeIntervalSince1970:))
    }

    var numericBlockNumber: UInt64? {
        UInt64(blockNumber.value)
    }
}

private struct EtherscanString: Codable {
    let value: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let string = try? container.decode(String.self) {
            value = string
        } else if let integer = try? container.decode(UInt64.self) {
            value = String(integer)
        } else {
            throw DecodingError.typeMismatch(
                String.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected a string or integer.")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
} // swiftlint:disable:this file_length
