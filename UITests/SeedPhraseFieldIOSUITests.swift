//
//  SeedPhraseFieldIOSUITests.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 11.11.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

#if os(iOS)
import XCTest
import XCUIAutomation

/// The iOS counterpart of `SeedPhraseFieldMacUITests`: taps and the
/// software keyboard instead of clicks and pasting.
final class SeedPhraseFieldIOSUITests: XCTestCase {
    private static let valid12 = Array(repeating: "abandon", count: 11) + ["about"]

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false

        app = XCUIApplication(bundleIdentifier: "xyz.reefr.wallet")
        app.launchArguments = ["--test"]
        app.launch()
    }

    func testTypingCommitsChipsAndDeleteRemovesWholeWord() {
        openWordsStep()
        type(["test", "xxx"])

        XCTAssertEqual(app.firstDescendant(withIdentifier: "seed-phrase-word-0").value as? String, "valid")
        XCTAssertEqual(app.firstDescendant(withIdentifier: "seed-phrase-word-1").value as? String, "invalid")

        // Coordinate tap: on iPhone the keyboard-avoiding Form makes the
        // small button report as not hittable though a touch lands on it.
        app.firstDescendant(withIdentifier: "seed-phrase-remove-0")
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .tap()

        XCTAssertEqual(app.firstDescendant(withIdentifier: "seed-phrase-word-0").value as? String, "invalid")
        XCTAssertFalse(app.firstDescendant(withIdentifier: "seed-phrase-word-1").exists)
    }

    func testTypingAValidPhraseRestoresAKeyStore() {
        openWordsStep()
        type(Self.valid12)

        XCTAssertTrue(app.firstDescendant(withIdentifier: "seed-phrase-word-11").waitForExistence(timeout: 5))

        let restore = app.buttons["Restore"]
        XCTAssertTrue(restore.waitForExistence(timeout: 5))
        XCTAssertTrue(restore.isEnabled)
        restore.tap()

        XCTAssertTrue(app.staticTexts["Local Key"].waitForExistence(timeout: 10))
    }

    func testAWordBeyondTheCountIsRejectedWithAMessage() {
        openWordsStep()
        type(Self.valid12 + ["abandon"])

        XCTAssertTrue(app.firstDescendant(withIdentifier: "seed-phrase-message").waitForExistence(timeout: 5))
        XCTAssertFalse(app.firstDescendant(withIdentifier: "seed-phrase-word-12").exists)
        XCTAssertFalse(app.buttons["Restore"].isEnabled, "A rejected word leaves the input unresolved.")
    }

    func testGeneratingANewSlip39ShareShowsTwentyWordsAndAddsAKeyStore() {
        openAddKeyStore()
        option("New Mnemonic").tap()
        app.buttons["Next"].tap()

        let slip39 = option("SLIP-39")
        XCTAssertTrue(slip39.waitForExistence(timeout: 5))
        slip39.tap()
        app.buttons["Next"].tap()

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
        done.tap()

        XCTAssertTrue(app.staticTexts["Local Key"].waitForExistence(timeout: 10))
    }
}

private extension SeedPhraseFieldIOSUITests {
    func option(_ title: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", title))
            .firstMatch
    }

    /// Opens the Add Key Store sheet: an empty sidebar offers a button
    /// for it; otherwise it's in the sidebar's add menu.
    func openAddKeyStore() {
        let emptyStateButton = app.buttons["New Key Store"]

        if emptyStateButton.waitForExistence(timeout: 10) {
            emptyStateButton.tap()
            return
        }

        let addMenu = app.firstDescendant(withIdentifier: "sidebar-add-menu")
        XCTAssertTrue(addMenu.waitForExistence(timeout: 5))
        addMenu.tap()

        let item = app.buttons["Add Key Store"]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.tap()
    }

    /// Add Key Store → Restore From Backup → Next (type step) → words step.
    func openWordsStep() {
        openAddKeyStore()

        let restoreOption = option("Restore From Backup")
        XCTAssertTrue(restoreOption.waitForExistence(timeout: 5))
        restoreOption.tap()

        for _ in 0 ..< 2 {
            let next = app.buttons["Next"]
            XCTAssertTrue(next.waitForExistence(timeout: 5))
            next.tap()
        }

        XCTAssertTrue(app.firstDescendant(withIdentifier: "seed-phrase-editor").waitForExistence(timeout: 10))
    }

    /// One word at a time: a space commits each to a chip.
    func type(_ words: [String]) {
        let editor = app.firstDescendant(withIdentifier: "seed-phrase-editor")
        editor.tap()

        for word in words {
            app.typeText(word + " ")
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
#endif
