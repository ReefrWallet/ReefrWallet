import Foundation
import Moya
import WalletKit

protocol TransactionHistorySource {
    func supports(_ account: Account) -> Bool

    func transactionHistory(
        account: Account,
        request: BlockchainTransactionHistoryRequest
    ) async throws -> BlockchainTransactionPage
}

struct BlockscoutTransactionHistorySource: TransactionHistorySource {
    private let apiBaseURLs: [UInt64: URL]
    private let provider = MoyaProvider<BlockscoutAPI>()

    init(apiBaseURLs: [UInt64: URL] = [:]) {
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

    func supports(_ blockchain: WKBlockchain) -> Bool {
        apiBaseURL(for: blockchain) != nil
    }

    func transactionHistory(
        account: Account,
        request: BlockchainTransactionHistoryRequest
    ) async throws -> BlockchainTransactionPage {
        guard let apiBaseURL = apiBaseURL(for: account.blockchain) else {
            throw URLError(.unsupportedURL)
        }

        let pagination = try request.cursor.map {
            try JSONDecoder().decode(BlockscoutPagination.self, from: $0)
        }

        let response: BlockscoutTransactionsResponse = try await provider.request(
            .transactions(
                address: account.address,
                baseURL: apiBaseURL,
                pagination: pagination
            )
        )
        let transactions = response.items.map(\.blockchainTransaction)

        return BlockchainTransactionPage(
            transactions: transactions,
            nextCursor: try response.nextPageParams.map(JSONEncoder().encode),
            reachedBoundary: response.nextPageParams == nil,
            head: transactions.map(\.blockHeight).compactMap { $0 }.max()
        )
    }
}

private extension BlockscoutTransactionHistorySource {
    func apiBaseURL(for blockchain: WKBlockchain) -> URL? {
        guard case let .evm(chain) = blockchain else {
            return nil
        }

        return apiBaseURLs[chain.chainId]
    }
}

private enum BlockscoutAPI {
    case transactions(address: String, baseURL: URL, pagination: BlockscoutPagination?)
}

extension BlockscoutAPI: TargetType {
    var baseURL: URL {
        switch self {
        case let .transactions(_, baseURL, _):
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
        case let .transactions(address, _, _):
            "addresses/\(address)/transactions"
        }
    }

    var sampleData: Data {
        Data()
    }

    var task: Task {
        switch self {
        case let .transactions(_, _, pagination):
            guard let pagination else {
                return .requestPlain
            }

            return .requestParameters(
                parameters: pagination.parameters,
                encoding: URLEncoding.queryString
            )
        }
    }
}

private struct BlockscoutAddress: Codable {
    let hash: String
}

private struct BlockscoutPagination: Codable {
    let blockNumber: UInt64
    let index: UInt64
    let itemsCount: UInt64

    var parameters: [String: Any] {
        [
            "block_number": blockNumber,
            "index": index,
            "items_count": itemsCount
        ]
    }
}

private struct BlockscoutTransaction: Codable {
    let blockNumber: UInt64
    let from: BlockscoutAddress
    let hash: String
    let timestamp: String
    let to: BlockscoutAddress?

    var blockchainTransaction: BlockchainTransaction {
        BlockchainTransaction(
            identifier: hash,
            blockHeight: blockNumber,
            timestamp: ISO8601DateFormatter.blockscout.date(from: timestamp),
            sender: from.hash,
            recipient: to?.hash,
            status: .confirmed,
            rawPayload: try? JSONEncoder().encode(self)
        )
    }
}

private struct BlockscoutTransactionsResponse: Decodable {
    let items: [BlockscoutTransaction]
    let nextPageParams: BlockscoutPagination?
}

private extension ISO8601DateFormatter {
    static let blockscout: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
