import SwiftUI
import WalletKit

struct RelativeTimestampLabel: View {
    let timestamp: Date?

    var body: some View {
        if let timestamp {
            Text(timestamp, format: .relative(presentation: .named))
                .style(.small, foreground: .secondary)
        }
    }
}

struct TransactionAmountLabel: View {
    let amount: Decimal?
    let symbol: String

    var body: some View {
        if let amount {
            Text("\(amount.formatted(.number.precision(.fractionLength(0...6)))) \(symbol)")
                .style(.mediumHeader, foreground: amount < 0 ? .negative : amount > 0 ? .positive : .secondary)
        }
    }
}

struct TransactionStatusBadge: View {
    let status: BlockchainTransactionStatus

    var body: some View {
        Text(status.rawValue.capitalized)
            .style(.small, foreground: status == .confirmed ? .positive : .secondary)
    }
}

struct TruncatedIdentifierLabel: View {
    let identifier: String
    let accessibilityIdentifier: String

    var body: some View {
        Text(identifier)
            .accessibilityIdentifier(accessibilityIdentifier)
            .lineLimit(1)
            .truncationMode(.middle)
            .style(.small, foreground: .secondary)
    }
}
