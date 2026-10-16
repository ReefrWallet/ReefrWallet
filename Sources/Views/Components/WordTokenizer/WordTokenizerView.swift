//
//  WordTokenizerView.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 22.09.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI
import UniformTypeIdentifiers
import WalletKit

/// Tokenizes a BIP39 recovery phrase into per-word chips, colored green
/// or red against `wordlist`, with typing restricted to the wordlist's
/// characters and support for selection, in-place editing, inserting a
/// word between two others, and drag reordering.
///
/// `phrase` is a plain space-joined `String`, so it drops straight into
/// call sites that already validate the whole phrase (e.g.
/// `Mnemonic.fromPhrase`) unchanged.
struct WordTokenizerView: View {
    enum FocusTarget: Hashable {
        case chip(UUID)
        case editor(UUID)
    }

    @Binding var phrase: String

    var columns: Int?
    var readOnly = false
    var wordlist: Wordlist = .english

    @State private var model: WordTokenizerModel
    @State private var selectedId: UUID?
    @State private var editorSelections: [UUID: TextSelection] = [:]

    /// Set while deliberately cycling `focus` through `nil` to force the
    /// focused `TextField` to resync with a just-committed, cleared
    /// value (see `textBinding`). Guards the blur-commit handler below
    /// from treating that momentary `nil` as the user leaving the
    /// tokenizer and deleting the editor it's mid-refocus on.
    @State private var isRefocusingAfterCommit = false

    @FocusState private var focus: FocusTarget?

    init(
        phrase: Binding<String>,
        columns: Int? = nil,
        readOnly: Bool = false,
        wordlist: Wordlist = .english
    ) {
        self._phrase = phrase
        self.columns = columns
        self.readOnly = readOnly
        self.wordlist = wordlist
        self._model = State(initialValue: WordTokenizerModel(wordlist: wordlist))
    }

    var body: some View {
        Group {
            if let columns {
                eagerGrid(columns: columns)
            } else {
                WrapLayout(spacing: 8) {
                    chips
                }
            }
        }
        .contentShape(Rectangle())
        #if os(macOS)
        .focusSection()
        #endif
        .onTapGesture { tapEmptyArea() }
        .onChange(of: phrase, initial: true) { _, newValue in
            guard newValue != model.phrase else {
                return
            }

            model.load(phrase: newValue)
        }
        .onChange(of: focus) { oldValue, newValue in
            guard let oldValue,
                  case .editor = oldValue else {
                return
            }

            if let newValue,
               case .editor = newValue {
                return
            }

            guard !isRefocusingAfterCommit else {
                return
            }

            model.commitEditor()
            syncPhrase()
        }
        .onChange(of: wordlist) { _, newValue in
            model.setWordlist(newValue)
        }
    }
}

// MARK: - Chips

private extension WordTokenizerView {
    var index: WordlistIndex {
        WordlistIndex.index(for: wordlist)
    }

    @ViewBuilder
    var chips: some View {
        ForEach(Array(model.entries.enumerated()), id: \.element.id) { offset, entry in
            chip(offset: offset, entry: entry)
        }
    }

    /// A grid with a fixed column count, built eagerly (`VStack`/`HStack`,
    /// never `LazyVGrid`): a `LazyVGrid` only materializes its cells as
    /// needed, and can tear down and rebuild a cell's underlying platform
    /// view when the grid re-evaluates layout — which drops keyboard
    /// focus out from under whichever `.editor` chip is being typed into.
    /// The chip list here is small and bounded (a mnemonic tops out at 24
    /// words), so eager layout costs nothing and keeps every chip's
    /// identity, and its focus, stable.
    @ViewBuilder
    func eagerGrid(columns: Int) -> some View {
        let indexedEntries = Array(model.entries.enumerated())
        let rowCount = (indexedEntries.count + columns - 1) / columns

        VStack(alignment: .leading, spacing: 8) {
            ForEach(0 ..< rowCount, id: \.self) { row in
                HStack(alignment: .top, spacing: 8) {
                    ForEach(0 ..< columns, id: \.self) { column in
                        let entryIndex = row * columns + column

                        if entryIndex < indexedEntries.count {
                            let (offset, entry) = indexedEntries[entryIndex]
                            chip(offset: offset, entry: entry)
                                .frame(minWidth: 80, maxWidth: .infinity, alignment: .leading)
                        } else {
                            Color.clear.frame(minWidth: 80, maxWidth: .infinity)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    func chip(offset: Int, entry: WordTokenizerModel.Entry) -> some View {
        WordTokenView(
            entry: entry,
            index: offset,
            isSelected: selectedId == entry.id,
            expandsToFill: columns != nil,
            isValid: index.contains(entry.text),
            readOnly: readOnly,
            text: textBinding(for: entry.id),
            selection: selectionBinding(for: entry.id),
            focus: $focus,
            focusTarget: focusTarget(for: entry),
            onEditorKeyPress: { press in
                handleKeyPress(press, on: entry)
            },
            onTap: { tapWord(id: entry.id) }
        )
        .modifier(EntryFocusableModifier(entry: entry, readOnly: readOnly))
        .onKeyPress { press in
            handleKeyPress(press, on: entry)
        }
        .modifier(DragReorderModifier(entry: entry, readOnly: readOnly) { draggedID in
            guard let source = model.entries.firstIndex(where: { $0.id == draggedID }),
                  let destination = model.entries.firstIndex(where: { $0.id == entry.id }) else {
                return false
            }

            model.move(from: source, to: destination)
            syncPhrase()

            return true
        })
    }

    func focusTarget(for entry: WordTokenizerModel.Entry) -> FocusTarget {
        switch entry {
        case let .word(id, _): .chip(id)
        case let .editor(id, _): .editor(id)
        }
    }

    func selectionBinding(for id: UUID) -> Binding<TextSelection?> {
        Binding(
            get: { editorSelections[id] },
            set: { editorSelections[id] = $0 }
        )
    }

    /// Collapses the caret to the end of `id`'s text instead of leaving
    /// its selection up to the system default. AppKit selects all text
    /// when a `TextField` freshly becomes first responder — harmless for
    /// an editor that's empty (as right after committing a word), but
    /// for an editor seeded with an existing word (as when walking back
    /// into one with backspace) it means the very next keystroke replaces
    /// the whole word instead of editing it.
    func collapseSelectionToEnd(for id: UUID) {
        let text = model.entries.first(where: { $0.id == id })?.text ?? ""
        editorSelections[id] = TextSelection(insertionPoint: text.endIndex)
    }

    func textBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: { model.entries.first(where: { $0.id == id })?.text ?? "" },
            set: { newValue in
                guard let result = model.update(editorText: newValue, at: id) else {
                    return
                }

                syncPhrase()

                guard result.didCommitWord else {
                    return
                }

                // AppKit's field editor doesn't reliably pick up a value
                // this much shorter than what was just typed while it's
                // still the active edit session — it keeps showing, and
                // appending to, the raw keystrokes instead of the
                // model's cleared value, corrupting every word typed
                // after the first. Cycling focus off and back on (same
                // id, same view — no identity change) forces AppKit to
                // resign and reacquire the field editor, which picks up
                // the correct, cleared value on the way back in.
                isRefocusingAfterCommit = true
                focus = nil

                DispatchQueue.main.async {
                    focus = .editor(result.editorId)
                    isRefocusingAfterCommit = false

                    // See `editPreviousWord`: AppKit selects all of the
                    // field's text as part of becoming first responder,
                    // which must be overridden a tick after focus
                    // settles rather than alongside it. Usually a no-op
                    // (the tail is empty after a plain space commit),
                    // but a pasted multi-word phrase can leave a
                    // non-empty tail here too.
                    DispatchQueue.main.async {
                        collapseSelectionToEnd(for: result.editorId)
                    }
                }
            }
        )
    }
}

// MARK: - Interaction

private extension WordTokenizerView {
    func syncPhrase() {
        guard phrase != model.phrase else {
            return
        }

        phrase = model.phrase
    }

    func tapWord(id: UUID) {
        guard !readOnly else {
            return
        }

        model.beginEditing(at: id)
        syncPhrase()
        selectedId = nil
        focus = .editor(id)
    }

    func tapEmptyArea() {
        guard !readOnly else {
            return
        }

        selectedId = nil
        let id = model.insertEditor(at: model.entries.count)

        syncPhrase()
        focus = .editor(id)
    }

    /// Handles both chip-level key presses (letters seed a new edit,
    /// arrows begin the caret walk) and editor-level ones (backspace on an
    /// empty editor and arrows at an empty editor walk back out to the
    /// neighboring chip). Space isn't special-cased here: it's left
    /// `.ignored` so the `TextField` types it normally, which drives
    /// `textBinding`'s setter into `WordTokenizerModel.update` — the same
    /// path every other character and a pasted phrase already take.
    ///
    /// - Note: "At the editor's text edge" is approximated as "the editor
    ///   is empty" — SwiftUI's `TextField` doesn't expose a plain cursor
    ///   offset, and the common cases (a fresh caret, a fully-deleted
    ///   word) are both empty-editor states anyway.
    func handleKeyPress(_ press: KeyPress, on entry: WordTokenizerModel.Entry) -> KeyPress.Result {
        guard !readOnly else {
            return .ignored
        }

        switch entry {
        case .word(let id, _):
            return handleChipKeyPress(press, id: id)
        case let .editor(id, text):
            return handleEditorKeyPress(press, id: id, text: text)
        }
    }

    func handleChipKeyPress(_ press: KeyPress, id: UUID) -> KeyPress.Result {
        guard let position = model.entries.firstIndex(where: { $0.id == id }) else {
            return .ignored
        }

        switch press.key {
        case .leftArrow:
            beginCaret(at: position, seed: "")
            return .handled
        case .rightArrow:
            beginCaret(at: position + 1, seed: "")
            return .handled
        case .delete, .deleteForward:
            return .ignored
        default:
            // See `handleEditorKeyPress`: Backspace reaches here as the
            // raw U+007F character, not `KeyEquivalent.delete` — without
            // this it would fall through and seed a new edit with a
            // literal DEL character.
            guard !press.characters.isEmpty, press.characters != "\u{7F}" else {
                return .ignored
            }

            model.beginEditing(at: id)
            model.update(editorText: press.characters, at: id)
            syncPhrase()
            focus = .editor(id)
            selectedId = nil
            return .handled
        }
    }

    func handleEditorKeyPress(_ press: KeyPress, id: UUID, text: String) -> KeyPress.Result {
        guard text.isEmpty else {
            return .ignored
        }

        switch press.key {
        case .leftArrow:
            selectNeighbor(of: id, offset: -1, removingEmptyEditor: true)
            return .handled
        case .rightArrow:
            selectNeighbor(of: id, offset: 0, removingEmptyEditor: true)
            return .handled
        case .delete, .deleteForward:
            editPreviousWord(from: id)
            return .handled
        default:
            // The physical Backspace key, once it's passed through a
            // `TextField`'s own field editor, reaches `onKeyPress` as
            // U+007F (ASCII DEL) rather than `KeyEquivalent.delete`'s
            // documented U+0008 — matching only `.delete`/`.deleteForward`
            // silently drops it, leaving backspace on an empty editor a
            // no-op instead of walking back into the previous word.
            guard press.characters == "\u{7F}" else {
                return .ignored
            }

            editPreviousWord(from: id)
            return .handled
        }
    }

    /// Removes the empty editor and opens the preceding word for editing.
    func editPreviousWord(from id: UUID) {
        guard let position = model.entries.firstIndex(where: { $0.id == id }),
              position > model.entries.startIndex else {
            selectNeighbor(of: id, offset: -1, removingEmptyEditor: true)
            return
        }

        let previousId = model.entries[position - 1].id

        // Removing the trailing empty editor and converting the previous
        // word's `Button` into a `TextField` are kept as two separate
        // updates on purpose: doing both at once — a view disappearing
        // and a neighboring view morphing kind under the same id, in the
        // same render — keeps SwiftUI from reliably handing focus to the
        // newly-editing field on the first try.
        model.commitEditor()
        syncPhrase()

        DispatchQueue.main.async {
            self.model.beginEditing(at: previousId)
            self.selectedId = nil
            self.focus = .editor(previousId)

            // AppKit selects all of a `TextField`'s text as part of it
            // becoming first responder — that happens as a consequence
            // of the `focus` write above, so it must be overridden on a
            // later tick, once focus has actually settled, rather than
            // alongside it.
            DispatchQueue.main.async {
                self.collapseSelectionToEnd(for: previousId)
            }
        }
    }

    /// Inserts an empty editor at `position` (the caret) and focuses it —
    /// the first press of an arrow-key walk.
    func beginCaret(at position: Int, seed: String) {
        selectedId = nil

        let id = model.insertEditor(at: position)

        if !seed.isEmpty {
            model.update(editorText: seed, at: id)
        }

        syncPhrase()
        focus = .editor(id)
    }

    /// Removes the empty editor at `id` and selects the chip `offset`
    /// positions away — the second press of an arrow-key walk, or a
    /// backspace out of an empty editor.
    func selectNeighbor(of id: UUID, offset: Int, removingEmptyEditor: Bool) {
        guard let position = model.entries.firstIndex(where: { $0.id == id }) else {
            return
        }

        if removingEmptyEditor {
            model.commitEditor()
        }

        syncPhrase()

        let neighborPosition = position + offset
        guard model.entries.indices.contains(neighborPosition) else {
            focus = nil
            selectedId = nil
            return
        }

        let neighbor = model.entries[neighborPosition]
        selectedId = neighbor.id
        focus = .chip(neighbor.id)
    }
}

private struct EntryFocusableModifier: ViewModifier {
    let entry: WordTokenizerModel.Entry
    let readOnly: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        switch entry {
        case .editor:
            content
        case .word:
            content
                .focusable(!readOnly)
        }
    }
}

// MARK: - Drag reordering

/// A word's id, carried across a drag-to-reorder gesture.
private struct DraggedWord: Codable, Transferable {
    let id: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .data)
    }
}

/// Makes a `.word` chip draggable and a drop target that reorders the
/// dragged word to land in its place. A no-op for `.editor` entries and
/// while `readOnly`.
private struct DragReorderModifier: ViewModifier {
    let entry: WordTokenizerModel.Entry
    let readOnly: Bool
    let onDrop: (UUID) -> Bool

    func body(content: Content) -> some View {
        if readOnly {
            content
        } else {
            switch entry {
            case .word:
                content
                    .draggable(DraggedWord(id: entry.id))
                    .dropDestination(for: DraggedWord.self) { items, _ in
                        guard let dragged = items.first else {
                            return false
                        }

                        return onDrop(dragged.id)
                    }

            case .editor:
                content
            }
        }
    }
}

// MARK: - Preview

#if DEBUG

private let generatedPhrase = Mnemonic.generate(wordCount: .`24`).phrase

// swiftlint:disable:next line_length
private let invalidPhrase = "abandon notaword abandon abandon abandon abandon abandon abandon abandon abandon abandon art"

#Preview("Free-flow") {
    @Previewable @State var phrase = ""
    WordTokenizerView(phrase: $phrase)
        .frame(width: 440, alignment: .leading)
        .padding()
}

#Preview("Second word") {
    @Previewable @State var phrase = "test te"
    WordTokenizerView(phrase: $phrase)
        .frame(width: 440, alignment: .leading)
        .padding()
}

#Preview("4 columns") {
    @Previewable @State var phrase = generatedPhrase
    WordTokenizerView(phrase: $phrase, columns: 4)
        .frame(width: 440, alignment: .leading)
        .padding()
}

#Preview("Read-only") {
    @Previewable @State var phrase = generatedPhrase
    WordTokenizerView(phrase: $phrase, columns: 4, readOnly: true)
        .frame(width: 440, alignment: .leading)
        .padding()
}

#Preview("Invalid words") {
    @Previewable @State var phrase = invalidPhrase
    WordTokenizerView(phrase: $phrase, columns: 4)
        .padding()
}

#endif

// swiftlint:disable:this file_length
