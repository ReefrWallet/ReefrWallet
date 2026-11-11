//
//  SeedPhraseField.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 11.11.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI

/// A text field for a recovery phrase. Each completed word becomes a
/// numbered chip (green in the wordlist, red otherwise) with a × to delete
/// it; the word being typed stays plain text with a caret, in the grid
/// cell its chip will take. Chips sit in 4 columns on Mac and 3 on iOS.
///
/// Pasting works the same as typing, a whole phrase at once. Leaving the
/// field commits the word being typed. The field only edits `model`;
/// messages (rejected paste, checksum) belong to the caller.
struct SeedPhraseField: View {
    var model: SeedPhraseFieldModel
    /// Shows the words as chips only: no editing, no ×, no caret.
    var readOnly = false

    @FocusState private var focusedId: UUID?
    @State private var selections: [UUID: TextSelection] = [:]
    @State private var isRefocusing = false
    @State private var width: CGFloat = 0

    private var columns: Int { isIOS ? 3 : 4 }
    private var spacing: CGFloat { isIOS ? 8 : 10 }

    var body: some View {
        PhraseGridLayout(columns: columns, spacing: spacing) {
            ForEach(model.entries.filter { !readOnly || !$0.isEditor }) { entry in
                cell(for: entry)
            }
        }
        .padding(isIOS ? 12 : 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: isIOS ? 53 : 41, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: isIOS ? 10 : 5).fill(.background))
        .overlay {
            RoundedRectangle(cornerRadius: isIOS ? 10 : 5)
                .strokeBorder(
                    focusedId == nil ? Color.secondary.opacity(0.35) : Color.accentColor,
                    lineWidth: focusedId == nil ? 1 : 2
                )
        }
        .contentShape(Rectangle())
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onTapGesture { location in
            if !readOnly {
                tap(at: location)
            }
        }
        .onChange(of: focusedId) { old, new in
            guard old != nil, new == nil, !isRefocusing else {
                return
            }

            model.commitEditor()
        }
    }
}

// MARK: - Cells

private extension SeedPhraseField {
    @ViewBuilder
    func cell(for entry: SeedPhraseFieldModel.Entry) -> some View {
        switch entry {
        case let .word(id, text):
            NumberedWordToken(
                number: number(of: id),
                text: text,
                isValid: model.isValid(text),
                showsRemove: !readOnly,
                onEdit: { if !readOnly { edit(id) } },
                onRemove: { remove(id) }
            )

        case let .editor(id, text):
            editor(id: id, text: text)
                .layoutValue(key: IsCaretKey.self, value: text.isEmpty && !isLast(id))
        }
    }

    func editor(id: UUID, text: String) -> some View {
        TextField("", text: textBinding(for: id), selection: selectionBinding(for: id))
            .focused($focusedId, equals: id)
            .textFieldStyle(.plain)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .style(.medium, foreground: .primary)
            .padding(.leading, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onKeyPress { press in handle(press, id: id, text: text) }
            .accessibilityIdentifier("seed-phrase-editor")
    }

    func isLast(_ id: UUID) -> Bool {
        model.entries.last?.id == id
    }

    /// Chips and editor text before this entry, plus one.
    func number(of id: UUID) -> Int {
        guard let position = model.position(of: id) else {
            return 1
        }

        return model.entries.prefix(position).filter { !$0.text.isEmpty }.count + 1
    }

    func selectionBinding(for id: UUID) -> Binding<TextSelection?> {
        Binding(get: { selections[id] }, set: { selections[id] = $0 })
    }

    func textBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: { model.entries.first { $0.id == id }?.text ?? "" },
            set: { newValue in
                guard let result = model.update(editorText: newValue, at: id), result.didCommitWord else {
                    return
                }

                refocus(result.editorId)
            }
        )
    }
}

// MARK: - Interaction

private extension SeedPhraseField {
    func edit(_ id: UUID) {
        model.beginEditing(at: id)
        focus(id)
    }

    /// A tap between chips puts the caret there; elsewhere it goes to the end.
    func tap(at location: CGPoint) {
        let padding: CGFloat = isIOS ? 12 : 8
        let rowHeight: CGFloat = isIOS ? 29 : 25
        let cellWidth = (width - 2 * padding - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        guard cellWidth > 0 else {
            return focusEnd()
        }

        let gap = min(columns, max(0, Int(((location.x - padding) / (cellWidth + spacing)).rounded())))
        let row = max(0, Int((location.y - padding) / (rowHeight + spacing)))
        let cellIndex = row * columns + gap

        let chips = model.totalWordCount - (model.hasEditorWithText ? 1 : 0)

        guard cellIndex < chips, model.totalWordCount < model.wordCount else {
            return focusEnd()
        }

        focus(model.insertEditor(at: cellIndex))
    }

    /// Focus the end editor, adding one if there is room.
    func focusEnd() {
        if let last = model.entries.last, case .editor = last {
            focusedId = last.id
            return
        }

        guard model.totalWordCount < model.wordCount else {
            return
        }

        focus(model.insertEditor(at: model.entries.count))
    }

    func focus(_ id: UUID) {
        DispatchQueue.main.async {
            focusedId = id
            DispatchQueue.main.async { selections[id] = TextSelection(insertionPoint: editorText(id).endIndex) }
        }
    }

    func editorText(_ id: UUID) -> String {
        model.entries.first { $0.id == id }?.text ?? ""
    }

    func handle(_ press: KeyPress, id: UUID, text: String) -> KeyPress.Result {
        // Backspace reaches an empty editor as U+007F, not KeyEquivalent.delete.
        guard text.isEmpty, press.key == .delete || press.characters == "\u{7F}" else {
            return .ignored
        }

        keepEditorOnBlur()

        guard let previous = model.editPreviousWord(from: id) else {
            return .handled
        }

        focus(previous)
        return .handled
    }

    /// Clicking × takes focus from the editor, which would commit it away;
    /// keep the editor and give it focus back.
    func remove(_ id: UUID) {
        keepEditorOnBlur()
        model.remove(id: id)
        focusEnd()
    }

    /// Focus is about to move between editors; a momentary blur in between
    /// must not commit the editor being opened.
    func keepEditorOnBlur() {
        isRefocusing = true

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            isRefocusing = false
        }
    }

    /// AppKit keeps showing the raw keystrokes in a field editor whose
    /// value just shrank under it; cycling focus makes it resync.
    func refocus(_ id: UUID) {
        isRefocusing = true
        focusedId = nil

        DispatchQueue.main.async {
            focusedId = id
            isRefocusing = false
            DispatchQueue.main.async { selections[id] = TextSelection(insertionPoint: editorText(id).endIndex) }
        }
    }
}

// MARK: - Preview

#if DEBUG

#Preview("Typing") {
    @Previewable @State var model = SeedPhraseFieldModel(wordCount: 12, wordlist: .bip39(.english))
    SeedPhraseField(model: model)
        .frame(width: 560)
        .padding()
        .task { model.load(phrase: "abandon ability able te") }
}

#Preview("Empty") {
    @Previewable @State var model = SeedPhraseFieldModel(wordCount: 12, wordlist: .bip39(.english))
    SeedPhraseField(model: model)
        .frame(width: 560)
        .padding()
}

#Preview("Full") {
    @Previewable @State var model = SeedPhraseFieldModel(wordCount: 12, wordlist: .bip39(.english))
    SeedPhraseField(model: model)
        .frame(width: 560)
        .padding()
        .task { model.load(phrase: String(repeating: "abandon ", count: 11) + "about") }
}

#endif
