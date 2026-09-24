import Foundation
import WalletKit

enum TransactionRowKind: String, Hashable, Sendable {
    case approval
    case contractCall
    case multiAsset
    case received
    case selfTransfer
    case sent
    case unknown
}

struct TransactionRowEffect: Identifiable, Hashable, Sendable {
    let amount: Decimal?
    let assetIdentifier: String?
    let id: String
    let imageURL: URL?
    let kind: String
    let recipient: String?
    let sender: String?
    let symbol: String
}

struct TransactionRowModel: Identifiable, Hashable, Sendable {
    let blockHeight: UInt64?
    let effects: [TransactionRowEffect]
    let id: String
    let identifier: String
    let kind: TransactionRowKind
    let primaryEffect: TransactionRowEffect?
    let recipient: String?
    let sender: String?
    let status: BlockchainTransactionStatus
    let timestamp: Date?
}
