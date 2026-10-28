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

enum TransactionAssetClass: Hashable, Sendable {
    case nft(tokenId: String)
    case token
}

struct TransactionRowEffect: Identifiable, Hashable, Sendable {
    let amount: Decimal?
    let assetClass: TransactionAssetClass
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

extension TransactionRowEffect {
    /// Distinguishes assets: each NFT is its own asset, unlike fungible legs of one token.
    var assetKey: String? {
        switch assetClass {
        case let .nft(tokenId):
            "\(assetIdentifier ?? "")#\(tokenId)"
        case .token:
            assetIdentifier
        }
    }

    var isNFT: Bool {
        if case .nft = assetClass {
            return true
        }

        return false
    }
}

extension TransactionRowModel {
    /// Distinct assets changed by the transaction, e.g. "2 NFTs, 4 Tokens".
    var assetCountText: String {
        var nftKeys = Set<String?>()
        var tokenKeys = Set<String?>()

        for effect in effects {
            if effect.isNFT {
                nftKeys.insert(effect.assetKey)
            } else {
                tokenKeys.insert(effect.assetKey)
            }
        }

        let nfts = nftKeys.isEmpty ? nil : String(localized: .transactionRowNftCount(nftKeys.count))
        let tokens = tokenKeys.isEmpty ? nil : String(localized: .transactionRowTokenCount(tokenKeys.count))

        guard let nfts, let tokens else {
            return nfts ?? tokens ?? "—"
        }

        return String(localized: .transactionRowAssetCounts(nfts, tokens))
    }

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
            String(localized: .transactionRowApproval)
        case .contractCall:
            method ?? String(localized: .transactionRowContractCall)
        case .multiAsset:
            String(localized: .transactionRowAssetCount(effects.count))
        case .received:
            String(localized: .transactionRowReceived)
        case .selfTransfer:
            String(localized: .transactionRowSelfTransfer)
        case .sent:
            String(localized: .transactionRowSent)
        case .unknown:
            method ?? String(localized: .commonTransaction)
        }
    }
}
