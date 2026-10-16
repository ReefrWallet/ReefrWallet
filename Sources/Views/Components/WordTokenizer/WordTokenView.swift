//
//  WordTokenView.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 22.09.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI

/// Renders one `WordTokenizerModel.Entry`: a colored capsule chip for a
/// committed `.word`, or a borderless, content-sized `TextField` for the
/// in-progress `.editor`. Color reflects wordlist membership for `.word`s
/// only — the editor stays neutral, since a word's validity is only
/// meaningful once it's committed.
struct WordTokenView: View {
    let entry: WordTokenizerModel.Entry
    let index: Int
    let isSelected: Bool
    let expandsToFill: Bool
    let isValid: Bool
    let readOnly: Bool
    let text: Binding<String>
    let selection: Binding<TextSelection?>
    let focus: FocusState<WordTokenizerView.FocusTarget?>.Binding
    let focusTarget: WordTokenizerView.FocusTarget
    let onEditorKeyPress: (KeyPress) -> KeyPress.Result
    let onTap: () -> Void

    var body: some View {
        switch entry {
        case .word:
            wordChip
                .frame(maxWidth: expandsToFill ? .infinity : nil, alignment: .leading)
        case .editor:
            editor
                .frame(maxWidth: expandsToFill ? .infinity : nil, alignment: .leading)
        }
    }
}

private extension WordTokenView {
    var wordChip: some View {
        Button(action: onTap) {
            Text(text.wrappedValue)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isValid ? Color.positive : Color.negative)
        .background(
            Capsule()
                .fill((isValid ? Color.positive : Color.negative).opacity(0.15))
        )
        .overlay(
            Capsule()
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
        )
        .disabled(readOnly)
        .accessibilityIdentifier("word-tokenizer-word-\(index)")
        .accessibilityValue(isValid ? "valid" : "invalid")
    }

    var editor: some View {
        TextField("", text: text, selection: selection)
            .focused(focus, equals: focusTarget)
            .onKeyPress { press in
                onEditorKeyPress(press)
            }
            .textFieldStyle(.plain)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .style(.medium, foreground: .primary)
            .frame(minWidth: 56)
            .accessibilityIdentifier("word-tokenizer-editor-\(index)")
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background {
                Capsule()
                    .fill(.secondary.opacity(0.12))
            }
            .overlay {
                Capsule()
                    .strokeBorder(.secondary.opacity(0.35))
            }
    }
}

// MARK: - Preview

#if DEBUG

#Preview {
    @Previewable @FocusState var focus: WordTokenizerView.FocusTarget?

    HStack {
        WordTokenView(
            entry: .word(id: UUID(), text: "abandon"),
            index: 0,
            isSelected: false,
            expandsToFill: false,
            isValid: true,
            readOnly: false,
            text: .constant("abandon"),
            selection: .constant(nil),
            focus: $focus,
            focusTarget: .chip(UUID()),
            onEditorKeyPress: { _ in .ignored },
            onTap: {}
        )

        WordTokenView(
            entry: .word(id: UUID(), text: "zzz"),
            index: 1,
            isSelected: true,
            expandsToFill: false,
            isValid: false,
            readOnly: false,
            text: .constant("zzz"),
            selection: .constant(nil),
            focus: $focus,
            focusTarget: .chip(UUID()),
            onEditorKeyPress: { _ in .ignored },
            onTap: {}
        )

        WordTokenView(
            entry: .editor(id: UUID(), text: "ab"),
            index: 2,
            isSelected: false,
            expandsToFill: false,
            isValid: false,
            readOnly: false,
            text: .constant("ab"),
            selection: .constant(nil),
            focus: $focus,
            focusTarget: .editor(UUID()),
            onEditorKeyPress: { _ in .ignored },
            onTap: {}
        )
    }
    .padding()
}

#endif
