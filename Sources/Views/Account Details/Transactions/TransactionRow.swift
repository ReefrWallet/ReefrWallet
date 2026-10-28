import SwiftUI
import WalletKit

/// Mail-style list row: badge, then title/status/time, amount and counterparty lines.
struct TransactionRow: View {
    let model: TransactionRowModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            TransactionBadge(kind: model.kind)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.title)
                        .lineLimit(1)
                        .style(.headline, foreground: .primary)

                    TransactionStatusPill(model: model)

                    Spacer()

                    if let timestamp = model.timestamp {
                        Text(timestamp, format: .relative(presentation: .named))
                            .lineLimit(1)
                            .style(.callout, foreground: .secondary)
                    }

#if os(iOS)
                    Image(systemName: "chevron.right")
                        .style(.smallIcon, foreground: .secondary)
#endif
                }

                TransactionAmountText(model: model, size: isPhone ? .large : .medium)
                    .lineLimit(1)

                Text(model.subtitle)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .style(.callout, foreground: .secondary)
                    .help(model.sender ?? model.recipient ?? model.subtitle)
            }
        }
        .padding(.vertical, 6)
        .overlay(alignment: .topLeading) {
            TransactionAccessibilityData(model: model)
        }
    }
}
