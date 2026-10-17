import SwiftUI
import WalletKit

/// Invisible elements carrying raw row data under stable identifiers for UI tests, independent of layout.
struct TransactionAccessibilityData: View {
    let model: TransactionRowModel

    var body: some View {
        ZStack {
            marker("transaction-amount-\(model.identifier)", label: model.rawAmountText)
            marker("transaction-block-\(model.identifier)", label: model.blockHeight.map(String.init))
            marker("transaction-block-label-\(model.identifier)", label: model.blockLabel)
            marker("transaction-fee-\(model.identifier)", label: model.fee.map { "\($0) \(model.feeSymbol)" })
            marker("transaction-from-\(model.identifier)", label: model.sender)
            marker("transaction-hash-\(model.identifier)", label: model.identifier)
            marker("transaction-kind-\(model.identifier)", label: model.title)
                .accessibilityValue(model.kind.rawValue)
            marker("transaction-method-\(model.identifier)", label: model.method)
            marker("transaction-status-\(model.identifier)", label: model.status.rawValue.capitalized)
            marker("transaction-to-\(model.identifier)", label: model.recipient)
        }
        .frame(width: 1, height: 1)
        .clipped()
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func marker(_ identifier: String, label: String?) -> some View {
        if let label {
            Text(label)
                .foregroundStyle(.clear)
                .accessibilityIdentifier(identifier)
        }
    }
}

struct TransactionAmountText: View {
    let model: TransactionRowModel
    let size: StyledView.Size

    var body: some View {
        Text(model.amountText)
            .style(size, foreground: model.amountColor)
    }
}

struct TransactionBadge: View {
    let kind: TransactionRowKind

    var body: some View {
        Image(systemName: kind.symbolName)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(kind.tint)
            .frame(width: 40, height: 40)
            .background(kind.badgeBackground, in: Circle())
    }
}

struct TransactionStatusIcon: View {
    let model: TransactionRowModel
    let size: CGFloat

    var body: some View {
        if model.isFailed {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: size))
                .foregroundStyle(Color.negative)
                .accessibilityLabel("Failed")
        } else if model.isPending {
            Image(systemName: "clock")
                .font(.system(size: size))
                .foregroundStyle(Color.caution)
                .accessibilityLabel("Pending")
        }
    }
}

struct TransactionStatusPill: View {
    let model: TransactionRowModel

    var body: some View {
        if model.isFailed || model.isPending {
            let color = model.isFailed ? Color.negative : Color.caution

            Text(model.isFailed ? "Failed" : "Pending")
                .style(.caption, foreground: color)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(color.opacity(model.isFailed ? 0.14 : 0.16), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

extension TransactionRowKind {
    var badgeBackground: Color {
        switch self {
        case .contractCall, .sent:
            Color.negative.opacity(0.14)
        case .multiAsset, .received:
            Color.positive.opacity(0.14)
        case .approval, .selfTransfer, .unknown:
            Color.secondary.opacity(0.12)
        }
    }

    var symbolName: String {
        switch self {
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

    var tint: Color {
        switch self {
        case .contractCall, .sent:
            .negative
        case .multiAsset, .received:
            .positive
        case .approval, .selfTransfer, .unknown:
            .secondary
        }
    }
}

extension TransactionRowModel {
    var amountColor: Color {
        guard !isFailed, let amount = primaryEffect?.amount, amount != 0 else {
            return .secondary
        }

        switch kind {
        case .contractCall, .received, .sent:
            return amount > 0 ? .positive : .negative
        case .multiAsset:
            return .positive
        case .approval, .selfTransfer, .unknown:
            return .secondary
        }
    }

    var amountText: String {
        guard let effect = primaryEffect else {
            return "—"
        }

        guard let amount = effect.amount else {
            return effect.symbol
        }

        let magnitude = abs(amount).formatted(.number.precision(.fractionLength(0...6)))
        let sign = switch kind {
        case .approval, .selfTransfer, .unknown:
            ""
        case .contractCall, .multiAsset, .received, .sent:
            amount > 0 ? "+" : amount < 0 ? "−" : ""
        }

        return "\(sign)\(magnitude) \(effect.symbol)"
    }

    /// Unsigned-format amount the UI tests match against, e.g. "0.001 ETH" or "-0.5 SUI".
    var rawAmountText: String? {
        guard let effect = primaryEffect, let amount = effect.amount else {
            return nil
        }

        return "\(amount.formatted(.number.precision(.fractionLength(0...6)))) \(effect.symbol)"
    }

    var feeText: String {
        fee.map { $0.formatted(.number.precision(.fractionLength(0...8))) } ?? "—"
    }
}
