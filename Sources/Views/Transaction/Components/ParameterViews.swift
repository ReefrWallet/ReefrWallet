//
//  ParameterViews.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 21.10.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI
import WalletKit

// MARK: - AddressValue

/// Penpot `Address`: middle-truncated address over "Key store · Account".
struct AddressValue: View {
    let accountName: String
    let address: String
    var keyStoreName: String?

    var body: some View {
#if os(macOS)
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: address)
                .style(.medium, foreground: .primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(address)

            Text(verbatim: subtitle)
                .style(.small, foreground: .secondary)
        }
#else
        VStack(alignment: .trailing, spacing: 4) {
            Text(verbatim: address)
                .style(.callout, foreground: .secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Text(verbatim: subtitle)
                .style(.small, foreground: .secondary)
        }
#endif
    }

    private var subtitle: String {
        [keyStoreName, accountName].compactMap { $0 }.joined(separator: " · ")
    }
}

// MARK: - FromRow

/// The signing account, as an ``AddressValue``.
struct FromRow: View {
    let account: Account
    var title = "From"

    @State private var keyStoreName: String?

    var body: some View {
        ParameterRow(title) {
            AddressValue(accountName: account.name, address: displayAddress, keyStoreName: keyStoreName)
                .textSelection(.enabled)
        }
        .task(id: account.keyStoreId) {
            let databaseService = DI.injectOrFail(DatabaseService.self)
            keyStoreName = (try? await databaseService.fetchKeyStore(id: account.keyStoreId))?.name
        }
    }

    /// Cardano accounts are stored as account descriptors; show the receive address.
    private var displayAddress: String {
        guard case .cardano = account.blockchain else {
            return account.address
        }

        return (try? CardanoAccountDescriptor(string: account.address).receiveAddress.string) ?? account.address
    }
}

// MARK: - ParameterBlock

/// A titled monospaced box for raw bytes, call data and messages. Fits its
/// text and scrolls past `maxLines`.
struct ParameterBlock: View {
    private let maxLines: Int
    private let text: String
    private let title: String

    init(_ title: String, text: String, maxLines: Int = 10) {
        self.maxLines = maxLines
        self.text = text
        self.title = title
    }

    var body: some View {
        ParameterSection(title) {
            ScrollingMonoText(text, maxLines: maxLines)
#if os(macOS)
            .padding(12)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(.quaternary)
            }
#endif
        }
    }
}

// MARK: - ScrollingMonoText

/// Selectable monospaced text sized to its content, up to `maxLines` lines,
/// scrolling vertically beyond that.
struct ScrollingMonoText: View {
    private let maxLines: Int
    private let text: String

    @State private var fullHeight: CGFloat = 0
    @State private var limitedHeight: CGFloat = 0

    init(_ text: String, maxLines: Int) {
        self.maxLines = maxLines
        self.text = text
    }

    var body: some View {
        ScrollView {
            label
                .onGeometryChange(for: CGFloat.self, of: \.size.height) { fullHeight = $0 }
        }
        .frame(height: min(fullHeight, limitedHeight))
        .background(alignment: .top) {
            label
                .lineLimit(maxLines)
                .hidden()
                .onGeometryChange(for: CGFloat.self, of: \.size.height) { limitedHeight = $0 }
        }
    }

    private var label: some View {
        Text(verbatim: text)
            .style(.smallMono)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - ParameterLayout

/// The macOS label/value column geometry of rows.
enum ParameterLayout {
    static let columnSpacing: CGFloat = 12
    static let labelWidth: CGFloat = 188
}

// MARK: - ParameterRow

/// A label/value row: right-aligned label column on macOS, inset list row on iOS.
struct ParameterRow<Content: View>: View {
    private let content: Content
    private let label: String

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.content = content()
        self.label = label
    }

    var body: some View {
#if os(macOS)
        // Penpot: 440 pt rows with a right-aligned label column ending at 188 pt.
        HStack(alignment: .firstTextBaseline, spacing: ParameterLayout.columnSpacing) {
            Text(verbatim: label)
                .style(.small, foreground: .secondary)
                .multilineTextAlignment(.trailing)
                .frame(width: ParameterLayout.labelWidth, alignment: .trailing)

            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
#else
        LabeledContent {
            content
        } label: {
            Text(verbatim: label)
        }
#endif
    }
}

extension ParameterRow where Content == ParameterValue {
    init(_ label: String, value: String, subtitle: String? = nil, lineLimit: Int? = 1) {
        self.init(label) {
            ParameterValue(lineLimit: lineLimit, subtitle: subtitle, value: value)
        }
    }
}

// MARK: - TransactionCostRow

struct TransactionCostRow: View {
    var label: LocalizedStringResource = .transactionFeesTransactionCost
    let value: String

    var body: some View {
        ParameterRow(String(localized: label)) {
            // Keep the value's height and baseline while the USD cost is unavailable.
            Text(verbatim: value.isEmpty ? "0" : value)
                #if os(macOS)
                .style(.medium, foreground: .primary)
                #endif
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(value)
                .opacity(value.isEmpty ? 0 : 1)
                .accessibilityHidden(value.isEmpty)
                .allowsHitTesting(!value.isEmpty)
        }
    }
}

// MARK: - ParameterSection

/// A titled group of rows with an optional footer note: a stack on macOS, a form section on iOS.
struct ParameterSection<Content: View>: View {
    private let content: Content
    private let footer: String?
    private let footerColor: Color
    private let title: String?

    init(
        _ title: String? = nil,
        footer: String? = nil,
        footerColor: Color = .secondary,
        @ViewBuilder content: () -> Content
    ) {
        self.content = content()
        self.footer = footer
        self.footerColor = footerColor
        self.title = title
    }

    var body: some View {
#if os(macOS)
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(verbatim: title)
                    .style(.smallHeader, foreground: .secondary)
            }

            content

            if let footer {
                Text(verbatim: footer)
                    .style(.small, foreground: footerColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
#else
        Section {
            content
        } header: {
            if let title {
                Text(verbatim: title)
            }
        } footer: {
            if let footer {
                Text(verbatim: footer)
                    .style(.small, foreground: footerColor)
            }
        }
#endif
    }
}

// MARK: - ParameterValue

/// A selectable value with an optional caption below it.
struct ParameterValue: View {
    var lineLimit: Int? = 1
    var subtitle: String?
    let value: String

    var body: some View {
#if os(macOS)
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: value)
                .style(.medium, foreground: .primary)
                .lineLimit(lineLimit)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(value)

            if let subtitle, !subtitle.isEmpty {
                Text(verbatim: subtitle)
                    .style(.small, foreground: .secondary)
            }
        }
#else
        VStack(alignment: .trailing, spacing: 2) {
            Text(verbatim: value)
                .lineLimit(lineLimit)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(value)

            if let subtitle, !subtitle.isEmpty {
                Text(verbatim: subtitle)
                    .style(.small, foreground: .secondary)
            }
        }
#endif
    }
}

// MARK: - SignerSection

/// The requesting site and signing account of a message request. One section
/// on iOS; separate sections on macOS, as in Penpot.
struct SignerSection: View {
    let account: Account
    let site: String

    var body: some View {
#if os(macOS)
        ParameterSection {
            ParameterRow(String(localized: .commonSite), value: site)
        }

        ParameterSection {
            FromRow(account: account, title: String(localized: .commonAccount))
        }
#else
        ParameterSection {
            ParameterRow(String(localized: .commonSite), value: site)
            FromRow(account: account, title: String(localized: .commonAccount))
        }
#endif
    }
}
