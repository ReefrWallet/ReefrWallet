//
//  WordTokenizerUITests.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 23.09.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation
import XCTest
import XCUIAutomation

/// Drives the real `WordTokenizerView` inside `AddKeyStoreView`'s restore
/// flow end to end: typing a word and pressing space commits it and moves
/// editing to the next word; backspace on an empty editor walks back into
/// the previous word instead of deleting anything; and a fully-typed valid
/// mnemonic actually restores a key store.
final class WordTokenizerUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false

        app = XCUIApplication(bundleIdentifier: "xyz.reefr.wallet")
        app.launchArguments = ["--test"]
        app.launch()
        app.activate()
    }

    func testEnteringAndDeletingWordsWithBackspace() {
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        openRestoreFlow()

        let firstEditor = app.firstDescendant(withIdentifier: "word-tokenizer-editor-0")
        XCTAssertTrue(
            firstEditor.waitForExistence(timeout: 10),
            "Restore From Backup should start with the first word editable."
        )
        firstEditor.click()

        firstEditor.typeText("test")
        firstEditor.typeText(" ")

        let firstChip = app.firstDescendant(withIdentifier: "word-tokenizer-word-0")
        XCTAssertTrue(firstChip.waitForExistence(timeout: 5), "Space should commit \"test\" to a chip.")
        XCTAssertEqual(firstChip.value as? String, "valid", "\"test\" is a real BIP-39 word.")

        let secondEditor = app.firstDescendant(withIdentifier: "word-tokenizer-editor-1")
        XCTAssertTrue(
            secondEditor.waitForExistence(timeout: 5),
            "Committing the first word should move editing to the second word."
        )

        secondEditor.typeText("test")
        secondEditor.typeText(" ")

        let secondChip = app.firstDescendant(withIdentifier: "word-tokenizer-word-1")
        XCTAssertTrue(secondChip.waitForExistence(timeout: 5), "Space should commit the second \"test\" to a chip.")
        XCTAssertEqual(secondChip.value as? String, "valid")

        let thirdEditor = app.firstDescendant(withIdentifier: "word-tokenizer-editor-2")
        XCTAssertTrue(
            thirdEditor.waitForExistence(timeout: 5),
            "Committing the second word should move editing to the third word."
        )

        thirdEditor.typeText("xxx")
        thirdEditor.typeText(" ")

        let thirdChip = app.firstDescendant(withIdentifier: "word-tokenizer-word-2")
        XCTAssertTrue(thirdChip.waitForExistence(timeout: 5), "Space should commit \"xxx\" to a chip.")
        XCTAssertEqual(thirdChip.value as? String, "invalid", "\"xxx\" isn't a real BIP-39 word.")

        let fourthEditor = app.firstDescendant(withIdentifier: "word-tokenizer-editor-3")
        XCTAssertTrue(
            fourthEditor.waitForExistence(timeout: 5),
            "Committing the third word should move editing to the fourth word."
        )

        // Backspace on an empty editor walks back into the previous word
        // instead of deleting anything: the fourth editor should vanish
        // and the third word should reopen for editing with its text
        // intact.
        fourthEditor.typeKey(.delete, modifierFlags: [])

        let reopenedThirdEditor = app.firstDescendant(withIdentifier: "word-tokenizer-editor-2")
        XCTAssertTrue(
            reopenedThirdEditor.waitForExistence(timeout: 5),
            "Backspace on an empty editor should reopen the previous word for editing."
        )
        XCTAssertEqual(reopenedThirdEditor.value as? String, "xxx")
        XCTAssertFalse(
            app.firstDescendant(withIdentifier: "word-tokenizer-editor-3").exists,
            "There should be no fourth editor after backspacing out of it."
        )

        // Three more backspaces delete "xxx" one character at a time —
        // ordinary in-field editing, not the walk-back behavior above.
        reopenedThirdEditor.typeKey(.delete, modifierFlags: [])
        reopenedThirdEditor.typeKey(.delete, modifierFlags: [])
        reopenedThirdEditor.typeKey(.delete, modifierFlags: [])
        XCTAssertEqual(reopenedThirdEditor.value as? String, "")

        // Finishing the rest of a valid 12-word mnemonic (2 already
        // committed + these 9 + "junk" = 12) from here should behave
        // exactly like typing it from scratch.
        reopenedThirdEditor.typeText("test test test test test test test test test junk")

        let nextButton = app.buttons["Next"]
        XCTAssertTrue(nextButton.waitForExistence(timeout: 5))
        XCTAssertTrue(nextButton.isEnabled, "A valid 12-word mnemonic should enable Next.")

        nextButton.click()

        let localKeyLabel = app.staticTexts["Local Key"]
        XCTAssertTrue(
            localKeyLabel.waitForExistence(timeout: 10),
            "Restoring a valid mnemonic should add a new local key store to the sidebar."
        )
    }
}

private extension WordTokenizerUITests {
    func openRestoreFlow() {
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

        let nextButton = app.buttons["Next"]
        XCTAssertTrue(nextButton.waitForExistence(timeout: 5))
        nextButton.click()
    }
}

private extension XCUIApplication {
    func firstDescendant(withIdentifier identifier: String) -> XCUIElement {
        descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@", identifier))
            .firstMatch
    }
}
