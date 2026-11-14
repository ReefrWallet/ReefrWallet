import Foundation
import XCTest
import WalletKitTesting

/// Sends a Jetton (RTJ, 6 decimals) on the TON testnet from "Testnet #1" to "Testnet #2" through the Send UI and
/// checks both RTJ balances and both transaction lists, then returns it when the recipient holds enough Gram.
///
/// Uses `REEFR_TESTNET_MNEMONIC`; account 0 (m/44'/607'/0') needs RTJ (master
/// `kQDDqfCUyXigJ0xBa5m482BBZd56ebMnSIO2OLZVsqtpjF31`) and about 0.25 testnet GRAM for the attachment and fees.
@MainActor
final class TonTestnetJettonUITests: XCTestCase {
    private let sentAmount = "1"
    /// What the recipient must hold to pay for returning the Jetton.
    private let returnGram = 0.15

    private var app: XCUIApplication!
    private var recipientAddress = ""
    private var senderAddress = ""
    private var storeDirectory: URL!

    override func setUp() async throws {
        continueAfterFailure = false

        let mnemonic = ProcessInfo.processInfo.environment["REEFR_TESTNET_MNEMONIC"] ?? ""
        try XCTSkipIf(mnemonic.isEmpty, "Set REEFR_TESTNET_MNEMONIC to send on the TON testnet.")

        let seed = try Mnemonic.fromPhrase(mnemonic).toSeed()

        func address(index: UInt64) throws -> String {
            let path = try DerivationPath(.ton(.testnet), accountIndex: index, curve: .ed25519)
            let key = try seed.masterKey(curve: .ed25519).derive(path).privateKey()
            return try TonPKeySigner(network: .testnet, privateKey: key, derivationPath: path).address().string
        }

        senderAddress = try address(index: 0)
        recipientAddress = try address(index: 1)

        storeDirectory = FileManager.default.temporaryDirectory.appending(path: "ton-jetton-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)

        app = XCUIApplication(bundleIdentifier: "xyz.reefr.wallet")
        app.launchArguments = [
            "--test",
            "--store-path", storeDirectory.appending(path: "keystore.sqlite").path,
            "--mnemonic", mnemonic,
            "--create-ton-accounts"
        ]
    }

    override func tearDown() {
        app?.terminate()
        app = nil

        if let storeDirectory {
            try? FileManager.default.removeItem(at: storeDirectory)
        }
    }

    func testSendsAJettonBetweenAccounts() throws {
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        openAccount("Testnet #2")
        selectTab("Token Balances")
        let recipientBefore = balance("RTJ", timeout: 20) { _ in true } ?? 0
        let recipientGram = balance("GRAM", timeout: 20) { _ in true } ?? 0

        openAccount("Testnet #1")
        selectTab("Token Balances")
        let senderBefore = try XCTUnwrap(
            balance("RTJ", timeout: 90) { $0 >= 1 },
            "Account 0 needs at least 1 RTJ. Rows shown: \(visibleBalanceIds())"
        )

        send(symbol: "RTJ", amount: sentAmount, to: recipientAddress)

        let senderAfter = balance("RTJ", timeout: 180, refreshing: true) { $0 <= senderBefore - 1 }
        XCTAssertNotNil(senderAfter, "Expected the sender's RTJ balance to drop by \(sentAmount).")
        selectTab("Transactions")
        XCTAssertTrue(waitForTransaction(timeout: 120), "Expected the transfer in the sender's list.")

        openAccount("Testnet #2")
        selectTab("Token Balances")
        let recipientAfter = balance("RTJ", timeout: 180, refreshing: true) { $0 >= recipientBefore + 1 }
        XCTAssertNotNil(recipientAfter, "Expected the recipient's RTJ balance to grow.")
        selectTab("Transactions")
        XCTAssertTrue(waitForTransaction(timeout: 120), "Expected the transfer in the recipient's list.")

        guard recipientGram >= returnGram else {
            return
        }

        selectTab("Token Balances")
        send(symbol: "RTJ", amount: sentAmount, to: senderAddress)

        openAccount("Testnet #1")
        selectTab("Token Balances")
        let returned = balance("RTJ", timeout: 180, refreshing: true) { $0 > (senderAfter ?? 0) }
        XCTAssertNotNil(returned, "Expected the returned RTJ to reach the sender.")
    }
}

private extension TonTestnetJettonUITests {
    /// Sends `symbol` from the open account; expects its Token Balances tab to be showing.
    func send(symbol: String, amount: String, to address: String) {
        app.firstDescendant(withIdentifier: "balance-amount-\(symbol)").click()

        let sendButton = app.firstDescendant(withIdentifier: "account-send-button")
        XCTAssertTrue(sendButton.waitUntilEnabled(timeout: 10), "Expected Send to enable for \(symbol).")
        sendButton.click()

        let amountField = app.firstDescendant(withIdentifier: "transfer-amount-field")
        XCTAssertTrue(amountField.waitForExistence(timeout: 5))
        amountField.click()
        amountField.typeKey("a", modifierFlags: .command)
        amountField.typeText(amount)

        let receiverField = app.firstDescendant(withIdentifier: "transfer-receiver-field")
        XCTAssertTrue(receiverField.waitForExistence(timeout: 5))
        receiverField.click()
        receiverField.typeText(address)

        // Fee estimation emulates the whole trace, so it takes longer than for Gram.
        let nextButton = app.firstDescendant(withIdentifier: "transfer-next-button")
        XCTAssertTrue(nextButton.waitUntilEnabled(timeout: 60), "Expected Next to enable after fee estimation.")
        nextButton.click()

        let sheetTitle = app.firstDescendant(withIdentifier: "transfer-sheet-title")
        XCTAssertTrue(
            sheetTitle.waitUntilGone(timeout: 30),
            "Expected the Send sheet to dismiss after broadcast. Showing: \(visibleTexts())"
        )
    }

    /// An unlisted Jetton sits under the collapsed hidden-balances row; click its chevron.
    func expandHiddenBalancesIfCollapsed() {
        let triangle = app.outlines
            .matching(NSPredicate(format: "identifier == %@", "account-balances-content"))
            .firstMatch
            .descendants(matching: .disclosureTriangle)
            .firstMatch

        if triangle.exists, !triangle.isExpanded {
            triangle.click()
        }
    }

    func visibleTexts() -> [String] {
        app.staticTexts.allElementsBoundByIndex.map(\.text).filter { !$0.isEmpty }
    }

    func visibleBalanceIds() -> [String] {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "balance-"))
            .allElementsBoundByIndex
            .map(\.identifier)
    }

    func openAccount(_ name: String) {
        let account = app.firstDescendant(withIdentifier: "sidebar-account-label-\(name)")
        XCTAssertTrue(account.waitForExistence(timeout: 20))
        account.click()
    }

    func selectTab(_ label: String) {
        let tab = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", label))
            .firstMatch

        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        tab.click()
    }

    /// Polls `symbol`'s balance row, pressing Update between reads when `refreshing`.
    func balance(
        _ symbol: String,
        timeout: TimeInterval,
        refreshing: Bool = false,
        where condition: (Double) -> Bool
    ) -> Double? {
        let deadline = Date.now.addingTimeInterval(timeout)

        repeat {
            let row = app.firstDescendant(withIdentifier: "balance-amount-\(symbol)")
            expandHiddenBalancesIfCollapsed()

            if row.waitForExistence(timeout: 2), let value = Self.number(row.text), condition(value) {
                return value
            }

            let update = app.firstDescendant(withIdentifier: "sidebar-update-button")

            if refreshing, update.exists, update.isEnabled {
                update.click()
            }

            Thread.sleep(forTimeInterval: 3)
        } while Date.now < deadline

        return nil
    }

    /// Whether the open list has a row for the sent amount.
    func waitForTransaction(timeout: TimeInterval) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)

        while Date.now < deadline {
            let found = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "transaction-amount-"))
                .allElementsBoundByIndex
                .contains { $0.text.contains("RTJ") && $0.text.contains(sentAmount) }

            if found {
                return true
            }

            Thread.sleep(forTimeInterval: 3)
        }

        return false
    }

    static func number(_ text: String) -> Double? {
        Double(text.filter { $0.isNumber || $0 == "." || $0 == "," }.replacingOccurrences(of: ",", with: "."))
    }
}

private extension XCUIApplication {
    func firstDescendant(withIdentifier identifier: String) -> XCUIElement {
        descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@", identifier))
            .firstMatch
    }
}

private extension XCUIElement {
    func waitUntilEnabled(timeout: TimeInterval) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)

        while Date.now < deadline {
            if exists, isEnabled {
                return true
            }

            _ = waitForExistence(timeout: 0.2)
        }

        return exists && isEnabled
    }

    func waitUntilGone(timeout: TimeInterval) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)

        while Date.now < deadline {
            if !exists {
                return true
            }

            _ = waitForExistence(timeout: 0.2)
        }

        return !exists
    }
}
