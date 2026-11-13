//
//  SeedPhraseFieldMacUITests.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 11.11.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import AppKit
import Foundation
import XCTest
import XCUIAutomation

/// Drives the real `SeedPhraseField` inside the restore flow: a word becomes
/// a numbered chip on space, chips have a × to delete the whole word,
/// backspace on an empty editor reopens the previous word, a pasted phrase
/// of the right length restores a key store, and an over-long paste is
/// rejected with a message and leaves the input unchanged.
final class SeedPhraseFieldMacUITests: XCTestCase {
    private static let valid12 =
        "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        try requireASCIIKeyboardLayout()

        app = XCUIApplication(bundleIdentifier: "xyz.reefr.wallet")
        app.launchArguments = ["--test"]
        app.launch()
        app.activate()
    }

    func testTypingCommitsChipsAndDeleteRemovesWholeWord() {
        openWordsStep()

        let editor = app.firstDescendant(withIdentifier: "seed-phrase-editor")
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.click()
        editor.typeText("test ")

        let first = app.firstDescendant(withIdentifier: "seed-phrase-word-0")
        XCTAssertTrue(first.waitForExistence(timeout: 5), "Space should commit \"test\" to a chip.")
        XCTAssertEqual(first.value as? String, "valid")

        let nextEditor = app.firstDescendant(withIdentifier: "seed-phrase-editor")
        nextEditor.typeText("xxx ")

        let second = app.firstDescendant(withIdentifier: "seed-phrase-word-1")
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        XCTAssertEqual(second.value as? String, "invalid", "\"xxx\" isn't a BIP-39 word.")

        // × deletes the whole first word; the second renumbers to first.
        app.firstDescendant(withIdentifier: "seed-phrase-remove-0").click()
        XCTAssertEqual(app.firstDescendant(withIdentifier: "seed-phrase-word-0").value as? String, "invalid")
        XCTAssertFalse(app.firstDescendant(withIdentifier: "seed-phrase-word-1").exists)

        // Backspace on an empty editor reopens the previous word, text intact.
        let emptyEditor = app.firstDescendant(withIdentifier: "seed-phrase-editor")
        XCTAssertTrue(emptyEditor.waitForExistence(timeout: 5))
        emptyEditor.typeKey(.delete, modifierFlags: [])

        let reopened = app.firstDescendant(withIdentifier: "seed-phrase-editor")
        XCTAssertTrue(reopened.waitForExistence(timeout: 5))
        XCTAssertEqual(reopened.value as? String, "xxx")
    }

    func testPastingAValidPhraseWithoutTrailingSpaceRestoresAKeyStore() {
        openWordsStep()

        let editor = app.firstDescendant(withIdentifier: "seed-phrase-editor")
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.click()
        paste(Self.valid12)

        let restore = app.buttons["Restore"]
        XCTAssertTrue(restore.waitForExistence(timeout: 5))
        XCTAssertTrue(restore.isEnabled, "An exact-length valid paste should enable Restore at once.")
        restore.click()

        XCTAssertTrue(
            app.staticTexts["Local Key"].waitForExistence(timeout: 10),
            "Restoring should add a local key store to the sidebar."
        )
    }

    func testAnOverLongPasteIsRejectedWithAMessageAndKeepsTheInput() {
        openWordsStep()

        let editor = app.firstDescendant(withIdentifier: "seed-phrase-editor")
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.click()
        paste(Array(repeating: "abandon", count: 24).joined(separator: " "))

        XCTAssertTrue(app.firstDescendant(withIdentifier: "seed-phrase-message").waitForExistence(timeout: 5))
        XCTAssertFalse(app.firstDescendant(withIdentifier: "seed-phrase-word-0").exists, "Nothing should be added.")
    }

    func testGeneratingANewSlip39ShareShowsTwentyWordsAndAddsAKeyStore() {
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        let addMenu = app.firstDescendant(withIdentifier: "sidebar-add-menu")
        XCTAssertTrue(addMenu.waitForExistence(timeout: 10))
        addMenu.click()
        app.menuItems["Add Key Store"].click()

        let option = app
            .descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "New Mnemonic"))
            .firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5))
        option.click()
        app.buttons["Next"].click()

        let slip39 = app
            .descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "SLIP-39"))
            .firstMatch
        XCTAssertTrue(slip39.waitForExistence(timeout: 5))
        slip39.click()
        app.buttons["Next"].click()

        XCTAssertTrue(app.firstDescendant(withIdentifier: "seed-phrase-word-0").waitForExistence(timeout: 10))
        let words = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "seed-phrase-word-"))
        XCTAssertEqual(words.count, 20, "A share has 20 words.")
        XCTAssertFalse(
            app.firstDescendant(withIdentifier: "seed-phrase-remove-0").exists,
            "Generated words are read-only."
        )

        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        XCTAssertTrue(done.isEnabled)
        done.click()

        XCTAssertTrue(app.staticTexts["Local Key"].waitForExistence(timeout: 10))
    }
}

private extension SeedPhraseFieldMacUITests {
    func paste(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        app.typeKey("v", modifierFlags: .command)
    }

    /// Add Key Store → Restore From Backup → Next (type step) → words step.
    func openWordsStep() {
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        let addMenu = app.firstDescendant(withIdentifier: "sidebar-add-menu")
        XCTAssertTrue(addMenu.waitForExistence(timeout: 10))
        addMenu.click()

        let addKeyStoreItem = app.menuItems["Add Key Store"]
        XCTAssertTrue(addKeyStoreItem.waitForExistence(timeout: 5))
        addKeyStoreItem.click()

        let restoreOption = app
            .descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Restore From Backup"))
            .firstMatch
        XCTAssertTrue(restoreOption.waitForExistence(timeout: 5))
        restoreOption.click()

        for _ in 0 ..< 2 {
            let next = app.buttons["Next"]
            XCTAssertTrue(next.waitForExistence(timeout: 5))
            next.click()
        }
    }
}

private extension XCUIApplication {
    func firstDescendant(withIdentifier identifier: String) -> XCUIElement {
        descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@", identifier))
            .firstMatch
    }
}
