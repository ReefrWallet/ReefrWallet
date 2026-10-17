import SwiftUI
import WalletKit

/// Compact-width list row: badge · title + counterparty · amount + time.
struct TransactionRow: View {
    let model: TransactionRowModel

    var body: some View {
        HStack(spacing: 12) {
            TransactionBadge(kind: model.kind)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.title)
                        .lineLimit(1)
                        .style(.headline, foreground: .primary)

                    TransactionStatusPill(model: model)
                }

                Text(model.subtitle)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .style(.caption, foreground: .secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 2) {
                TransactionAmountText(model: model, size: .headline)

                if let timestamp = model.timestamp {
                    Text(timestamp, format: .relative(presentation: .named))
                        .style(.caption, foreground: .secondary)
                }
            }
            .lineLimit(1)
            .fixedSize()
        }
        .padding(.vertical, 6)
        .overlay(alignment: .topLeading) {
            TransactionAccessibilityData(model: model)
        }
    }
}
