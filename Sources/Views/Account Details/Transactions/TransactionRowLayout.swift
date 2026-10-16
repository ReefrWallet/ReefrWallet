import SwiftUI

struct TransactionRowLayout<Detail: View>: View {
    let model: TransactionRowModel
    let subtitle: String
    @ViewBuilder let detail: () -> Detail

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: directionImage)
                    .foregroundStyle(directionColor)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .accessibilityIdentifier("transaction-kind-\(model.identifier)")
                        .accessibilityValue(model.kind.rawValue)
                        .style(.mediumHeader, foreground: .primary)
                    Text(subtitle)
                        .style(.small, foreground: .secondary)
                    TruncatedIdentifierLabel(
                        identifier: model.identifier,
                        accessibilityIdentifier: "transaction-hash-\(model.identifier)"
                    )
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    TransactionAmountLabel(
                        amount: model.primaryEffect?.amount,
                        symbol: model.primaryEffect?.symbol ?? ""
                    )
                    .accessibilityIdentifier("transaction-amount-\(model.identifier)")
                    TransactionStatusBadge(status: model.status)
                        .accessibilityIdentifier("transaction-status-\(model.identifier)")
                    RelativeTimestampLabel(timestamp: model.timestamp)
                }
            }

            TransactionRowMetadata(model: model)

            DisclosureGroup("Details", isExpanded: $isExpanded) {
                detail()
                    .padding(.top, 4)
            }
            .style(.small, foreground: .secondary)
        }
        .padding(.vertical, 6)
    }

    private var directionColor: Color {
        switch model.kind {
        case .received:
            .positive
        case .sent:
            .negative
        default:
            .secondary
        }
    }

    private var directionImage: String {
        switch model.kind {
        case .approval:
            "checkmark.shield"
        case .contractCall:
            "chevron.left.forwardslash.chevron.right"
        case .multiAsset:
            "square.stack.3d.up"
        case .received:
            "arrow.down.left"
        case .selfTransfer:
            "arrow.left.arrow.right"
        case .sent:
            "arrow.up.right"
        case .unknown:
            "questionmark.circle"
        }
    }

    private var title: String {
        switch model.kind {
        case .approval:
            "Approval"
        case .contractCall:
            "Contract Call"
        case .multiAsset:
            "\(model.effects.count) Assets"
        case .received:
            "Received"
        case .selfTransfer:
            "Self Transfer"
        case .sent:
            "Sent"
        case .unknown:
            "Transaction"
        }
    }
}

private struct TransactionRowMetadata: View {
    let model: TransactionRowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let blockHeight = model.blockHeight {
                Text(String(blockHeight))
                    .accessibilityIdentifier("transaction-block-\(model.identifier)")
                    .style(.small, foreground: .secondary)
            }

            if let sender = model.sender {
                TruncatedIdentifierLabel(
                    identifier: sender,
                    accessibilityIdentifier: "transaction-from-\(model.identifier)"
                )
            }

            if let recipient = model.recipient {
                TruncatedIdentifierLabel(
                    identifier: recipient,
                    accessibilityIdentifier: "transaction-to-\(model.identifier)"
                )
            }
        }
    }
}

struct TransactionEffectsDetail: View {
    let effects: [TransactionRowEffect]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(effects) { effect in
                HStack {
                    Text(effect.kind)
                    Spacer()
                    TransactionAmountLabel(amount: effect.amount, symbol: effect.symbol)
                }
            }
        }
    }
}
