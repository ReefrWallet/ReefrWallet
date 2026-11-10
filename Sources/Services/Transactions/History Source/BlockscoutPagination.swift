import Foundation

/// Where a backfill stands in both lists it pages: transactions and ERC-20 transfers.
struct BlockscoutBackfillCursor: Codable {
    var transactions: BlockscoutPageParameters?
    var transactionsFinished = false
    var tokenTransfers: BlockscoutPageParameters?
    var tokenTransfersFinished = false

    init(
        transactions: BlockscoutPageParameters? = nil,
        transactionsFinished: Bool = false,
        tokenTransfers: BlockscoutPageParameters? = nil,
        tokenTransfersFinished: Bool = false
    ) {
        self.transactions = transactions
        self.transactionsFinished = transactionsFinished
        self.tokenTransfers = tokenTransfers
        self.tokenTransfersFinished = tokenTransfersFinished
    }

    /// A cursor saved by an older version holds only the transactions list's page
    /// parameters; its token transfers start over from the newest (writes are idempotent).
    init(storedCursor: Data) throws {
        if let cursor = try? JSONDecoder().decode(Self.self, from: storedCursor) {
            self = cursor
        } else {
            self.init(transactions: try JSONDecoder().decode(BlockscoutPageParameters.self, from: storedCursor))
        }
    }
}

/// Blockscout's opaque `next_page_params`, echoed back verbatim as query parameters.
struct BlockscoutPageParameters: Codable {
    let values: [String: BlockscoutScalar]

    init(from decoder: Decoder) throws {
        values = try decoder.singleValueContainer().decode([String: BlockscoutScalar].self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }

    /// Keys are snake-cased back: the shared decoder converts dictionary keys too.
    var parameters: [String: Any] {
        values.reduce(into: [:]) { result, item in
            guard let value = item.value.queryValue else {
                return
            }

            result[item.key.snakeCased] = value
        }
    }
}

enum BlockscoutScalar: Codable {
    case bool(Bool)
    case null
    case number(Double)
    case string(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case let .bool(value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        case let .number(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        }
    }

    var queryValue: Any? {
        switch self {
        case let .bool(value): value
        case .null:
            nil
        case let .number(value):
            value.rounded() == value ? Int64(value) as Any : value
        case let .string(value):
            value
        }
    }
}

fileprivate extension String {
    var snakeCased: String {
        reduce(into: "") { result, character in
            if character.isUppercase {
                result += "_" + character.lowercased()
            } else {
                result.append(character)
            }
        }
    }
}
