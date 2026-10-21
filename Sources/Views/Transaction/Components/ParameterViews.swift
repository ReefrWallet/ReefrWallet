//
//  ParameterViews.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 21.10.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI
import WalletKit

// MARK: - FromRow

/// The signing account: middle-truncated address over "Key store · Account".
struct FromRow: View {
    let account: Account
    var title = "From"

    @State private var keyStoreName: String?

    var body: some View {
        ParameterRow(title, value: displayAddress, subtitle: subtitle)
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

    private var subtitle: String {
        [keyStoreName, account.name].compactMap { $0 }.joined(separator: " · ")
    }
}

// MARK: - ParameterBlock

/// A titled monospaced box for raw bytes, call data and messages. Taller
/// content scrolls inside the box on macOS so the sheet keeps its size.
struct ParameterBlock: View {
    private let lineLimit: Int?
    private let text: String
    private let title: String

    init(_ title: String, text: String, lineLimit: Int? = nil) {
        self.lineLimit = lineLimit
        self.text = text
        self.title = title
    }

    var body: some View {
        ParameterSection(title) {
#if os(macOS)
            ViewThatFits(in: .vertical) {
                content
                ScrollView {
                    content
                }
            }
            .frame(maxHeight: 180)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(.quaternary)
            }
#else
            content
#endif
        }
    }

    private var content: some View {
        Text(text)
            .style(.smallMono)
            .lineLimit(lineLimit)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
#if os(macOS)
            .padding(12)
#endif
    }
}

// MARK: - ParameterLayout

/// The macOS label/value column geometry shared by rows and indented notes.
enum ParameterLayout {
    static let columnSpacing: CGFloat = 12
    static let labelWidth: CGFloat = 188
    static let valueInset = labelWidth + columnSpacing
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
            Text(label)
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
            Text(label)
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

// MARK: - ParameterSection

/// A titled group of rows with an optional footer note: a stack on macOS, a form section on iOS.
struct ParameterSection<Content: View>: View {
    private let content: Content
    private let footer: String?
    private let footerColor: Color
    /// Aligns the footer with the value column on macOS, under the section's fields.
    private let isFooterIndented: Bool
    private let title: String?

    init(
        _ title: String? = nil,
        footer: String? = nil,
        footerColor: Color = .secondary,
        isFooterIndented: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.content = content()
        self.footer = footer
        self.footerColor = footerColor
        self.isFooterIndented = isFooterIndented
        self.title = title
    }

    var body: some View {
#if os(macOS)
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(title)
                    .style(.smallHeader, foreground: .secondary)
            }

            content

            if let footer {
                Text(footer)
                    .style(.small, foreground: footerColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, isFooterIndented ? ParameterLayout.valueInset : 0)
            }
        }
#else
        Section {
            content
        } header: {
            if let title {
                Text(title)
            }
        } footer: {
            if let footer {
                Text(footer)
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
            Text(value)
                .style(.medium)
                .lineLimit(lineLimit)
                .truncationMode(.middle)
                .textSelection(.enabled)

            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .style(.small, foreground: .secondary)
            }
        }
#else
        VStack(alignment: .trailing, spacing: 2) {
            Text(value)
                .lineLimit(lineLimit)
                .truncationMode(.middle)
                .textSelection(.enabled)

            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .style(.small, foreground: .secondary)
            }
        }
#endif
    }
}
