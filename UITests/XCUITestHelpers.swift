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
