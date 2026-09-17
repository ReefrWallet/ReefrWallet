//
//  WatchOnlySuiAccountUITests.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 17.09.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import CoreGraphics
import Foundation
import XCTest
import XCUIAutomation

/// A real Sui testnet address expected to hold at least a native SUI
/// balance (and possibly other coin balances). Used to reproduce, against
/// live testnet data, a bug where balances that exist in the database
/// never render in `AccountDetailsView`.
private let suiTestnetAddress = "0x72e49ba9922e7641d6bd23c1f6fd6e30c195634485b8427c8fba8a98de6c03b0"

/// A real Sui testnet address holding only a non-native coin (USDC), no
/// native SUI balance. Used to reproduce a related bug: an account whose
/// only balances are unpriced (and therefore hidden) coins showed "Zero
/// Balances" instead of a balances table with a reachable "Hidden
/// Balances" disclosure.
private let usdcOnlySuiTestnetAddress = "0x0394a0edf52d7164a995311b56031a7e8262dff33566edcbd7b1279d380cf0bd"

final class WatchOnlySuiAccountUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false

        app = XCUIApplication(bundleIdentifier: "xyz.reefr.wallet")
        // `--test` runs the app against a fresh in-memory SwiftData store
        // (see `Inject.InjectionMode.test`), so accounts and their
        // balances are always created from scratch — no stale on-disk
        // data from a previous run can mask (or fake) the bug.
        app.launchArguments = ["--test"]
        app.launch()
    }

    /// Adds a watch-only Sui Testnet account for a real address, fetches
    /// its balances from the live network, and asserts the balances
    /// table actually renders them instead of showing "Zero Balances".
    ///
    /// Then adds a second watch-only account whose only balance is an
    /// unpriced (hidden) coin, and asserts the balances table — and its
    /// "Hidden Balances" disclosure — still render, with the coin
    /// reachable once the disclosure is expanded.
    func testWatchOnlySuiAccountDisplaysFetchedBalances() {
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))

        addWatchOnlyAccount(address: suiTestnetAddress)
        triggerBalancesUpdate()

        let totalValueLabel = app.staticTexts["Total Value:"]
        XCTAssertTrue(
            totalValueLabel.waitForExistence(timeout: 10),
            "Expected the balances table to show at least one entry for \(suiTestnetAddress), " +
                "but the account details view never left its empty state."
        )

        XCTAssertFalse(
            app.staticTexts["Zero Balances"].exists,
            "Balances table should not be reporting zero balances once the update finishes."
        )

        addWatchOnlyAccount(address: usdcOnlySuiTestnetAddress)
        triggerBalancesUpdate()

        // This account holds no native SUI — its only balance is an
        // unpriced coin, which is hidden from the main entries list. The
        // balances table (and its "Hidden Balances" disclosure) must
        // still render instead of falling back to "Zero Balances".
        let hiddenDisclosureRow = app.firstDescendant(withIdentifier: "balances-table-hidden-disclosure-row")
        XCTAssertTrue(
            hiddenDisclosureRow.waitForExistence(timeout: 10),
            "The Hidden Balances disclosure row itself should be visible for \(usdcOnlySuiTestnetAddress)."
        )

        XCTAssertFalse(
            app.staticTexts["Zero Balances"].exists,
            "An account whose only balance is unpriced (hidden) should still render the balances table, " +
                "not fall back to the Zero Balances placeholder."
        )

        // `DisclosureTableRow` is backed by an `NSOutlineView` disclosure
        // triangle on macOS — a distinct AX element from the row's label
        // text, and the one that actually toggles expansion when clicked.
        let disclosureTriangle = app.disclosureTriangles.firstMatch
        XCTAssertTrue(disclosureTriangle.waitForExistence(timeout: 5))
        disclosureTriangle.click()

        let usdcBalanceLabel = app.staticTexts["USDC"]
        XCTAssertTrue(
            usdcBalanceLabel.waitForExistence(timeout: 5),
            "USDC balance should be visible once the Hidden Balances disclosure is expanded."
        )
    }
}

// MARK: - Steps

private extension WatchOnlySuiAccountUITests {
    func addWatchOnlyAccount(address: String) {
        openAddWatchOnlyAccountSheet()
        selectSuiTestnetNetwork()
        enterWatchAddress(address)
        submitAddAccount()
    }

    func openAddWatchOnlyAccountSheet() {
        let addMenu = app.firstDescendant(withIdentifier: "sidebar-add-menu")
        XCTAssertTrue(addMenu.waitForExistence(timeout: 5))
        addMenu.click()

        let addWatchOnlyItem = app.menuItems["Add Watch-Only Account"]
        XCTAssertTrue(addWatchOnlyItem.waitForExistence(timeout: 5))
        addWatchOnlyItem.click()
    }

    func selectSuiTestnetNetwork() {
        let blockchainPicker = app.firstDescendant(withIdentifier: "add-account-blockchain-picker")
        XCTAssertTrue(blockchainPicker.waitForExistence(timeout: 5))
        blockchainPicker.click()

        let suiMenuItem = app.menuItems["Sui"]
        XCTAssertTrue(suiMenuItem.waitForExistence(timeout: 5))
        suiMenuItem.click()

        let networkPicker = app.firstDescendant(withIdentifier: "add-account-network-picker")
        XCTAssertTrue(networkPicker.waitForExistence(timeout: 5))
        networkPicker.click()

        let testnetMenuItem = app.menuItems["Sui Testnet"]
        XCTAssertTrue(testnetMenuItem.waitForExistence(timeout: 5))
        testnetMenuItem.click()
    }

    func enterWatchAddress(_ address: String) {
        let addressField = app.textFields["add-account-watch-address-field"]
        XCTAssertTrue(addressField.waitForExistence(timeout: 5))
        addressField.click()
        addressField.typeText(address)
    }

    func submitAddAccount() {
        let submitButton = app.firstDescendant(withIdentifier: "add-account-submit-button")
        XCTAssertTrue(submitButton.waitForExistence(timeout: 5))
        XCTAssertTrue(submitButton.isEnabled, "Add Account should be enabled once a valid address is entered.")
        submitButton.click()

        let sheetDismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: submitButton
        )
        wait(for: [sheetDismissed], timeout: 5)
    }

    func triggerBalancesUpdate() {
        let updateButton = app.firstDescendant(withIdentifier: "sidebar-update-button")
        XCTAssertTrue(updateButton.waitForExistence(timeout: 5))
        XCTAssertTrue(updateButton.isEnabled, "Update should be enabled once at least one account exists.")
        updateButton.click()
    }
}

// MARK: - Helpers

private extension XCUIApplication {
    /// Finds an element by accessibility identifier regardless of its
    /// concrete AX role (menu button, popup button, plain button, ...) —
    /// SwiftUI's macOS role mapping for `Menu`/`Picker` isn't reliable
    /// enough across styles/OS versions to hardcode a specific
    /// `XCUIElementQuery` type.
    func firstDescendant(withIdentifier identifier: String) -> XCUIElement {
        descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@", identifier))
            .firstMatch
    }
}
