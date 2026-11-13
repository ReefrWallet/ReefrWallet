#if os(macOS)
import Carbon
#endif
import XCTest

extension XCUIApplication {
    /// Waits for the unknown-token (hidden) balance rows.
    ///
    /// The balances list shows every token by default, so there is nothing to expand;
    /// a live backfill keeps rewriting balances, so just wait for the rows.
    func expandHiddenBalances(timeout: TimeInterval = 10) {
        let hiddenRows = descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "balance-row-hidden-"))

        XCTAssertTrue(hiddenRows.firstMatch.waitForExistence(timeout: timeout), "Expected hidden balance rows.")
    }

    /// Adds `url` as a sidebar dApp (or selects the existing one) and opens
    /// it in a Browser window.
    func openDappInBrowser(_ url: String, timeout: TimeInterval = 10) {
        // The add button only appears while the section header is hovered.
        let header = descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Connected dApps"))
            .firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: timeout), "Expected the sidebar's Connected dApps header.")
        header.hover()

        let addButton = descendant(withIdentifier: "sidebar-add-dapp-button")
        XCTAssertTrue(addButton.waitForExistence(timeout: 5), "Expected the sidebar's Add dApp button.")
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

extension XCTestCase {
    /// Under a non-Latin input source (e.g. Russian) `typeText` holds ⌘ to
    /// reach Latin keys, so text arrives as shortcuts. Fail at once instead
    /// of timing out.
    func requireASCIIKeyboardLayout() throws {
#if os(macOS)
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let isASCII = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsASCIICapable) else {
            return
        }

        guard !CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(isASCII).takeUnretainedValue()) else {
            return
        }

        let name = TISGetInputSourceProperty(source, kTISPropertyLocalizedName)
            .map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String } ?? "current"
        throw NSError(domain: "KeyboardLayout", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "The \(name) input source can't type Latin text; switch to ABC."
        ])
#endif
    }
}
