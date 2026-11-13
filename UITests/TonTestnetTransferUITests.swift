import Foundation
import XCTest
import WalletKitTesting

/// Sends Gram on the TON testnet from "Testnet #1" to "Testnet #2" through the Send UI and checks that both
/// balances update and the transfer shows up in both transaction lists.
///
/// Uses `REEFR_TESTNET_MNEMONIC`; account 0 (m/44'/607'/0') needs about 0.25 testnet GRAM. The recipient
/// returns what it received minus a fee reserve, so only fees are spent.
@MainActor
final class TonTestnetTransferUITests: XCTestCase {
    private let sentAmount = "0.05"
    /// Left with the recipient: its compute fee plus the return transfer's own fees.
    private let returnReserve = Decimal(string: "0.02")!

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

        storeDirectory = FileManager.default.temporaryDirectory.appending(path: "ton-\(UUID().uuidString)")
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

    func testSendsGramBetweenAccounts() throws {
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        // The recipient's starting balance, read before anything is sent.
        openAccount("Testnet #2")
        selectTab("Token Balances")
        let recipientBefore = try XCTUnwrap(waitForBalance(timeout: 60) { _ in true })

        openAccount("Testnet #1")
        selectTab("Token Balances")
        let senderBefore = try XCTUnwrap(waitForBalance(timeout: 60) { $0 > 0.25 }, "Fund account 0 with testnet GRAM.")

        send(amount: sentAmount, to: recipientAddress)

        // The sender pays the amount plus fees.
        let senderAfter = waitForBalance(timeout: 120, refreshing: true) { $0 < senderBefore - 0.05 }
        XCTAssertNotNil(senderAfter, "Expected the sender's GRAM balance to drop by at least \(sentAmount).")
        selectTab("Transactions")
        XCTAssertTrue(waitForTransaction(timeout: 120), "Expected the transfer in the sender's list.")

        openAccount("Testnet #2")
        selectTab("Token Balances")
        let recipientAfter = waitForBalance(timeout: 120, refreshing: true) { $0 > recipientBefore }
        XCTAssertNotNil(recipientAfter, "Expected the recipient's GRAM balance to grow.")

        selectTab("Transactions")
        XCTAssertTrue(waitForTransaction(timeout: 120), "Expected the transfer in the recipient's list.")

        // Return the funds; the recipient's first send deploys its wallet.
        let received = try XCTUnwrap(recipientAfter) - recipientBefore
        let returned = received - returnReserve
        XCTAssertGreaterThan(returned, 0)
        selectTab("Token Balances")
        send(amount: "\(returned)", to: senderAddress)

        openAccount("Testnet #1")
        selectTab("Token Balances")
        let senderReturned = waitForBalance(timeout: 120, refreshing: true) { $0 > (senderAfter ?? 0) }
        XCTAssertNotNil(senderReturned, "Expected the returned GRAM to reach the sender.")
    }
}

private extension TonTestnetTransferUITests {
    /// Sends GRAM from the open account; expects its Token Balances tab to be showing.
    func send(amount: String, to address: String) {
        app.firstDescendant(withIdentifier: "balance-amount-GRAM").click()

        let sendButton = app.firstDescendant(withIdentifier: "account-send-button")
        XCTAssertTrue(sendButton.waitUntilEnabled(timeout: 10), "Expected Send to enable for GRAM.")
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

        let nextButton = app.firstDescendant(withIdentifier: "transfer-next-button")
        XCTAssertTrue(nextButton.waitUntilEnabled(timeout: 20), "Expected Next to enable after fee estimation.")
        nextButton.click()

        let sheetTitle = app.firstDescendant(withIdentifier: "transfer-sheet-title")
        XCTAssertTrue(sheetTitle.waitUntilGone(timeout: 30), "Expected the Send sheet to dismiss after broadcast.")
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

    /// Polls the GRAM balance row, pressing Update between reads when `refreshing`.
    func waitForBalance(
        timeout: TimeInterval,
        refreshing: Bool = false,
        where condition: (Decimal) -> Bool
    ) -> Decimal? {
        let deadline = Date.now.addingTimeInterval(timeout)

        repeat {
            let row = app.firstDescendant(withIdentifier: "balance-amount-GRAM")

            if row.waitForExistence(timeout: 2), let value = Self.decimal(row.text), condition(value) {
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
                .contains { $0.text.contains(Decimal(string: sentAmount)!.formatted(.number)) }

            if found {
                return true
            }

            Thread.sleep(forTimeInterval: 3)
        }

        return false
    }

    static func decimal(_ text: String) -> Decimal? {
        Decimal(string: text.filter { $0.isNumber || $0 == "." || $0 == "," }.replacingOccurrences(of: ",", with: "."))
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
