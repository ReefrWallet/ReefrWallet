//
//  NumberedWordToken.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 11.11.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI

/// A committed word: its number, the word (green in the wordlist, red
/// otherwise) and a × that deletes the whole word.
struct NumberedWordToken: View {
    let number: Int
    let text: String
    let isValid: Bool
    var showsRemove = true
    let onEdit: () -> Void
    let onRemove: () -> Void

    /// Extra touch area around the ×, without changing the layout.
    private var touchInset: CGFloat { isIOS ? 8 : 0 }

    private var tint: Color { isValid ? .positive : .negative }

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onEdit) {
                HStack(spacing: 4) {
                    Text(verbatim: "\(number):")
                        .style(.small, foreground: .secondary)
                    Text(verbatim: text)
                        .style(.medium, foreground: tint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("seed-phrase-word-\(number - 1)")
            .accessibilityValue(isValid ? "valid" : "invalid")

            if showsRemove {
                removeButton
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, showsRemove ? 4 : 8)
        .padding(.vertical, isIOS ? 4 : 2)
        .background(
            RoundedRectangle(cornerRadius: isIOS ? 6 : 4)
                .fill(tint.opacity(0.15))
        )
    }

    private var removeButton: some View {
        Button(action: onRemove) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 16, height: 16)
                .padding(touchInset)
                .contentShape(Rectangle())
                .padding(-touchInset)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: "Remove word \(number)"))
        .accessibilityIdentifier("seed-phrase-remove-\(number - 1)")
    }
}
