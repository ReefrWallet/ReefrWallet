#if DEBUG
import SwiftUI
import WalletKit

extension TransactionRowModel {
    /// Every kind in every status, mirroring the Figma "Transaction Row" component sheet.
    static var previews: [TransactionRowModel] {
        let kinds: [TransactionRowKind] = [
            .received, .sent, .selfTransfer, .approval, .contractCall, .multiAsset, .unknown
        ]

        let statuses: [BlockchainTransactionStatus] = [.confirmed, .unconfirmed, .failed]

        return kinds.flatMap { kind in
            statuses.map { status in
                preview(kind: kind, status: status)
            }
        }
    }

    static func preview(kind: TransactionRowKind, status: BlockchainTransactionStatus) -> TransactionRowModel {
        let identifier = "0x5d1e09\(kind.rawValue)\(status.rawValue)a8c3f2"
        let amount: Decimal = switch kind {
        case .received, .multiAsset:
            0.25
        case .sent, .contractCall:
            -0.25
        case .approval:
            0
        case .selfTransfer, .unknown:
            0.25
        }

        let effect = TransactionRowEffect(
            amount: amount,
            assetIdentifier: nil,
            id: identifier,
            imageURL: nil,
            kind: "nativeTransfer",
            recipient: nil,
            sender: nil,
            symbol: "ETH"
        )

        return TransactionRowModel(
            blockHeight: status == .unconfirmed ? nil : 23_581_204,
            blockLabel: status == .unconfirmed ? "Pending" : "Block #23581204",
            effects: kind == .multiAsset ? [effect, effect] : [effect],
            fee: 0.00021986,
            feeSymbol: "ETH",
            fromLabel: kind == .received ? "0x18A2…b89A" : "Main Account",
            id: identifier,
            identifier: identifier,
            kind: kind,
            method: kind == .contractCall ? "Swap" : "Transfer",
            primaryEffect: effect,
            recipient: nil,
            sender: nil,
            status: status,
            subtitle: kind == .received ? "From 0x71C7…976F" : "To 0x71C7…976F",
            timestamp: .now.addingTimeInterval(-7_200),
            toLabel: kind == .received ? "Main Account" : "0x71C7…976F"
        )
    }
}

#Preview("Rows") {
    List(TransactionRowModel.previews) { model in
        TransactionRow(model: model)
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
    }
    .listStyle(.plain)
}

#Preview("Table") {
    TransactionsTable(
        rows: TransactionRowModel.previews,
        schema: TransactionRowPresenters.presenter(for: .evm(.ethereum(.mainnet))).schema
    )
}
#endif
