import Foundation
import XCTest

/// Connects the real app.uniswap.org with Ethereum and Solana mainnet accounts:
/// Uniswap asks for Ethereum when its Reefr row is picked and for Solana right
/// after, so approving both must leave both chains configured on the dapp.
/// Nothing is signed or sent. Skipped when Uniswap is unreachable.
@MainActor
final class UniswapConnectionUITests: XCTestCase {
    private static let url = "https://app.uniswap.org"
    private let mnemonic = "test test test test test test test test test test test junk"
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        try requireASCIIKeyboardLayout()

        do {
            // swiftlint:disable:next force_unwrapping
            let (_, response) = try await URLSession.shared.data(from: URL(string: Self.url)!)
            try XCTSkipUnless((response as? HTTPURLResponse)?.statusCode == 200, "Uniswap is unreachable.")
        } catch is XCTSkip {
            throw XCTSkip("Uniswap is unreachable.")
        } catch {
            throw XCTSkip("Uniswap is unreachable: \(error)")
        }

        app = XCUIApplication(bundleIdentifier: "xyz.reefr.wallet")
        app.launchArguments = [
            "--test",
            "-ApplePersistenceIgnoreState", "YES",
            "--mnemonic", mnemonic,
            "--create-ethereum-mainnet-accounts",
            "--create-solana-mainnet-accounts"
        ]
    }

    func testConnectingEthereumThenSolanaConfiguresBoth() {
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        app.openDappInBrowser(Self.url)
        XCTAssertTrue(
            element("browser-address-field").waitForExistence(timeout: 10),
            "Expected the Browser window to open."
        )

        // Uniswap's page load, including its Solana wallet adapter's auto-connect, must not prompt.
        XCTAssertFalse(
            element("dapp-request-title").waitForExistence(timeout: 12),
            "No Connect Request may appear before pressing Connect."
        )

        // Uniswap's pink Connect button (top right) opens the wallet dialog. The dialog's text is in
        // the page even while it is closed, so only an on-screen "Connect" counts.
        let connect = onScreenElement(labeled: "Connect", timeout: 30)
        XCTAssertNotNil(connect, "Expected Uniswap's Connect button. \(webSummary())")
        connect?.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()

        // The wallet's row in the dialog (clicked by coordinate: web content is rarely "hittable").
        let reefr = onScreenElement(labeled: "Reefr Wallet", timeout: 15)
        XCTAssertNotNil(reefr, "Expected Reefr in Uniswap's wallet list. \(webSummary())")
        reefr?.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()

        let ethereum = element("dapp-account-picker-ethereum")
        XCTAssertTrue(ethereum.waitForExistence(timeout: 20), "Expected an Ethereum drop-down. \(webSummary())")
        element("dapp-approve-button").click()

        // Uniswap asks for Solana only once Ethereum is connected, as a second request.
        XCTAssertTrue(
            element("dapp-approve-button").waitForExistence(timeout: 20),
            "Expected Uniswap's follow-up Solana Connect Request. \(webSummary())"
        )

        element("dapp-approve-button").click()

        // Both chains are configured on the dapp, each with an account.
        let ethereumRow = element("dapp-account-picker-ethereum")
        let solanaRow = element("dapp-account-picker-solana")
        XCTAssertTrue(
            ethereumRow.waitForExistence(timeout: 15),
            "Expected an Ethereum selector in the dapp's settings."
        )

        XCTAssertTrue(solanaRow.exists, "Expected a Solana selector in the dapp's settings.")
        XCTAssertNotEqual(ethereumRow.value as? String, "Not connected")
        XCTAssertNotEqual(solanaRow.value as? String, "Not connected")

        // The toolbar capsule summarises the two connected accounts.
        let capsule = element("browser-account-selector")
        let summary = NSPredicate(format: "label BEGINSWITH %@", "2 accounts (")
        XCTAssertEqual(
            XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: summary, object: capsule)], timeout: 10),
            .completed,
            "Expected \"2 accounts (Ethereum, Solana)\" in the capsule, got \"\(capsule.label)\"."
        )
    }
}

// MARK: - Helpers

private extension UniswapConnectionUITests {
    var web: XCUIElement {
        app.webViews.firstMatch
    }

    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@", identifier))
            .firstMatch
    }

    func webElement(labelBeginsWith prefix: String) -> XCUIElement {
        web.descendants(matching: .any)
            // Web text publishes its content as the AX value, not the label.
            .matching(NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@", prefix, prefix))
            .firstMatch
    }

    /// The first element labelled `text` whose frame lies inside the window. Uniswap also keeps a
    /// hidden copy of its wallet dialog below the window, which `firstMatch` would pick first.
    func onScreenElement(labeled text: String, timeout: TimeInterval) -> XCUIElement? {
        // A popover trigger such as Connect exposes its text as the element's title.
        let predicate = NSPredicate(format: "label == %@ OR value == %@ OR title == %@", text, text, text)
        let deadline = Date.now.addingTimeInterval(timeout)

        while Date.now < deadline {
            // The web view reports its whole scrolled content, so use the window.
            let address = element("browser-address-field").frame
            let viewport = app.windows.allElementsBoundByIndex.map(\.frame).first { $0.contains(address) } ?? web.frame
            let candidates = web.descendants(matching: .any).matching(predicate).allElementsBoundByIndex
            let found = candidates.first { $0.exists && viewport.contains($0.frame) && $0.elementType != .image }

            if let match = found {
                return match
            }

            RunLoop.current.run(until: .now.addingTimeInterval(0.5))
        }

        return nil
    }

    /// The labels and values on the page, for failure messages.
    func webSummary() -> String {
        guard let snapshot = try? app.snapshot() else {
            return "(no snapshot)"
        }

        var texts: [String] = []

        func visit(_ node: XCUIElementSnapshot) {
            let text = node.label.isEmpty ? "\(node.value ?? "")" : node.label
            if !text.isEmpty, node.elementType != .window {
                texts.append(text)
            }

            node.children.forEach(visit)
        }

        visit(snapshot)
        return texts.prefix(60).joined(separator: " | ")
    }

    /// Every element whose label or value mentions `text`, for failure messages,
    /// read from one consistent snapshot of the app.
    func diagnostics(_ text: String) -> String {
        guard let snapshot = try? app.snapshot() else {
            return "(no snapshot)"
        }

        var found: [String] = []

        func visit(_ node: XCUIElementSnapshot) {
            let value = "\(node.value ?? "")"
            if node.label.localizedCaseInsensitiveContains(text) || value.localizedCaseInsensitiveContains(text) {
                found.append("[\(node.elementType.rawValue) id=\(node.identifier) label=\(node.label) value=\(value)]")
            }

            node.children.forEach(visit)
        }

        visit(snapshot)
        return found.prefix(10).joined(separator: " ")
    }
}
