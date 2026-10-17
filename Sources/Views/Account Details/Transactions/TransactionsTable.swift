import SwiftUI
import WalletKit

/// Regular-width transactions table. iPad shows one fixed column set; Mac follows the chain's `schema`.
struct TransactionsTable: View {
    let rows: [TransactionRowModel]
    let schema: TransactionTableSchema

    @State private var selection: TransactionRowModel.ID?

    var body: some View {
        Table(rows, selection: $selection) {
            TableColumn("") { model in
                TransactionStatusIcon(model: model, size: Self.statusIconSize)
                    .frame(maxWidth: .infinity)
                    .background(alignment: .topLeading) {
                        TransactionAccessibilityData(model: model)
                    }
            }
            .width(Self.statusColumnWidth)

            TableColumn("Date") { model in
                Text(model.timestamp.map(Self.dateText) ?? "—")
                    .style(Self.textSize, foreground: .secondary)
            }
            .width(min: 90, ideal: 126)

            TableColumn(schema.methodTitle) { model in
                Text(model.method ?? model.title)
                    .style(Self.textSize, foreground: .primary)
            }
            .width(min: 80, ideal: 124)

            #if os(macOS)
            macColumns
            #else
            TableColumn("Counterparty") { model in
                Text(model.subtitle)
                    .truncationMode(.middle)
                    .style(.callout, foreground: .primary)
            }
            .width(min: 120, ideal: 198)

            TableColumn(schema.hashTitle) { model in
                Text(model.identifier.shortened(prefix: 8, suffix: 6))
                    .style(.mono, foreground: .secondary)
            }
            .width(min: 100, ideal: 140)
            #endif

            TableColumn(schema.amountTitle) { model in
                TransactionAmountText(model: model, size: Self.monoSize)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 90, ideal: 140)

            TableColumn(schema.feeTitle) { model in
                Text(model.feeText)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .style(Self.monoSize, foreground: Self.feeColor)
            }
            .width(min: 60, ideal: 92)
        }
    }
}

#if os(macOS)
private extension TransactionsTable {
    static let feeColor = Color.secondary
    static let monoSize = StyledView.Size.smallMono
    static let statusColumnWidth: CGFloat = 22
    static let statusIconSize: CGFloat = 12
    static let textSize = StyledView.Size.small

    static func dateText(_ date: Date) -> String {
        date.formatted(
            Date.VerbatimFormatStyle(
                format: """
                \(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \
                \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)
                """,
                timeZone: .current,
                calendar: .current
            )
        )
    }

    @TableColumnBuilder<TransactionRowModel, Never>
    var macColumns: some TableColumnContent<TransactionRowModel, Never> {
        TableColumn(schema.hashTitle) { model in
            Text(model.identifier.shortened(prefix: 8, suffix: 6))
                .style(.smallMono, foreground: .primary)
        }
        .width(min: 90, ideal: 128)

        TableColumn(schema.blockTitle) { model in
            Text(model.blockHeight.map(String.init) ?? "—")
                .style(.smallMono, foreground: .primary)
        }
        .width(min: 60, ideal: 80)

        TableColumn(schema.fromTitle ?? "") { model in
            Text(model.fromLabel ?? "—")
                .truncationMode(.middle)
                .style(.small, foreground: .primary)
        }
        .width(min: 80, ideal: 130)
        .defaultVisibility(schema.fromTitle == nil ? .hidden : .automatic)

        TableColumn("") { model in
            Text(model.direction.rawValue)
                .frame(maxWidth: .infinity)
                .style(.small, foreground: model.direction.color)
        }
        .width(40)
        .defaultVisibility(schema.showsDirection ? .automatic : .hidden)

        TableColumn(schema.toTitle ?? "") { model in
            Text(model.toLabel ?? "—")
                .truncationMode(.middle)
                .style(.small, foreground: .primary)
        }
        .width(min: 80, ideal: 140)
        .defaultVisibility(schema.toTitle == nil ? .hidden : .automatic)
    }
}

private extension TransactionDirection {
    var color: Color {
        switch self {
        case .incoming:
            .positive
        case .outgoing:
            .negative
        case .none, .selfTransfer:
            .secondary
        }
    }
}
#else
private extension TransactionsTable {
    static let feeColor = Color.secondary.opacity(0.6)
    static let monoSize = StyledView.Size.mono
    static let statusColumnWidth: CGFloat = 32
    static let statusIconSize: CGFloat = 16
    static let textSize = StyledView.Size.callout

    static func dateText(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)

        guard !Calendar.current.isDateInToday(date) else {
            return "Today, \(time)"
        }

        return "\(date.formatted(.dateTime.month(.abbreviated).day())), \(time)"
    }
}
#endif
