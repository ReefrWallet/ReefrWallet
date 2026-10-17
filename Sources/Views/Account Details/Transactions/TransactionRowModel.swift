import Foundation
import WalletKit

enum TransactionDirection: String, Hashable, Sendable {
    case incoming = "IN"
    case none = ""
    case outgoing = "OUT"
    case selfTransfer = "SELF"
}

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
    /// Chain-specific block coordinate, e.g. "Block #1", "Slot 1", "Version 1".
    let blockLabel: String
    let effects: [TransactionRowEffect]
    /// Fee in the native asset.
    let fee: Decimal?
    let feeSymbol: String
    /// Table "From" cell: sender, or the account name when it's ours.
    let fromLabel: String?
    let id: String
    let identifier: String
    let kind: TransactionRowKind
    let method: String?
    let primaryEffect: TransactionRowEffect?
    let recipient: String?
    let sender: String?
    let status: BlockchainTransactionStatus
    /// One-line counterparty: "From 0x71C7…976F", "To …" or a contract/program name.
    let subtitle: String
    let timestamp: Date?
    /// Table "To"/"Program"/"Activity With" cell.
    let toLabel: String?
}

extension TransactionRowModel {
    var direction: TransactionDirection {
        switch kind {
        case .received:
            .incoming
        case .approval, .contractCall, .sent:
            .outgoing
        case .selfTransfer:
            .selfTransfer
        case .multiAsset, .unknown:
            .none
        }
    }

    var isFailed: Bool {
        status == .failed || status == .reverted
    }

    var isPending: Bool {
        status == .broadcast || status == .unconfirmed
    }

    var title: String {
        switch kind {
        case .approval:
            "Approval"
        case .contractCall:
            method ?? "Contract Call"
        case .multiAsset:
            "\(effects.count) Assets"
        case .received:
            "Received"
        case .selfTransfer:
            "Self Transfer"
        case .sent:
            "Sent"
        case .unknown:
            method ?? "Transaction"
        }
    }
}
