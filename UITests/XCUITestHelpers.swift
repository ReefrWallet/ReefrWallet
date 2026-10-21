import XCTest

extension XCUIApplication {
    /// Expands the balances table's Hidden Balances section.
    ///
    /// Clicking the section's row only selects it — `DisclosureTableRow` toggles
    /// from the outline's disclosure triangle, so that is what gets clicked.
    ///
    /// A live backfill keeps rewriting balances underneath the table, so the
    /// click can land on a row the next refresh replaces. Retry until the hidden
    /// rows are actually on screen.
    func expandHiddenBalances(timeout: TimeInterval = 10) {
        let triangle = outlines
            .matching(NSPredicate(format: "identifier == %@", "account-balances-content"))
            .firstMatch
            .descendants(matching: .disclosureTriangle)
            .firstMatch

        XCTAssertTrue(triangle.waitForExistence(timeout: 10), "Expected a Hidden Balances disclosure triangle.")

        let hiddenRows = descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "balance-row-hidden-"))
        let deadline = Date.now.addingTimeInterval(timeout)

        while Date.now < deadline {
            if hiddenRows.firstMatch.exists {
                return
            }

            if triangle.exists, !triangle.isExpanded {
                triangle.click()
            }

            _ = hiddenRows.firstMatch.waitForExistence(timeout: 2)
        }

        XCTFail("Hidden Balances never expanded.")
    }

    /// Adds `url` as a sidebar dApp (or selects the existing one) and opens
    /// it in a Browser window.
    func openDappInBrowser(_ url: String, timeout: TimeInterval = 10) {
        let addButton = descendant(withIdentifier: "sidebar-add-dapp-button")
        XCTAssertTrue(addButton.waitForExistence(timeout: timeout), "Expected the sidebar's Add dApp button.")
        // The section header merges into one element with the button's
        // identifier, so click the trailing "+" rather than the center.
        addButton.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
            .withOffset(CGVector(dx: -18, dy: 0))
            .click()

        let urlField = descendant(withIdentifier: "add-dapp-url-field")
        XCTAssertTrue(urlField.waitForExistence(timeout: 5), "Expected the Add dApp sheet.")
        urlField.click()
        urlField.typeText(url)
        descendant(withIdentifier: "add-dapp-add-button").click()

        let openButton = descendant(withIdentifier: "dapp-open-button")
        XCTAssertTrue(openButton.waitForExistence(timeout: 5), "Expected the dApp details pane.")
        openButton.click()
    }

    private func descendant(withIdentifier identifier: String) -> XCUIElement {
        descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@", identifier))
            .firstMatch
    }
}

extension XCUIElement {
    /// Whether a disclosure triangle is currently pointing open.
    var isExpanded: Bool {
        switch value {
        case let number as Int:
            number != 0
        case let string as String:
            string != "0"
        default:
            false
        }
    }

    /// The string a static text actually renders.
    ///
    /// AppKit backs SwiftUI's `Text` with elements that publish their content
    /// as the accessibility *value* and leave `label` empty, so asserting on
    /// `label` alone silently compares against `""`.
    var text: String {
        guard label.isEmpty else {
            return label
        }

        return value as? String ?? ""
    }
}
