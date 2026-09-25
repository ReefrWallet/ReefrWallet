import Foundation
import XCTest
import WalletKitTesting

/// Regression coverage for the forward-sync gap: a transaction broadcast
/// after the initial backfill completes must still reach the recipient's
/// transaction list without a relaunch. Unlike `SuiTransactionHistoryUITests`
/// (which broadcasts directly via `SuiGRPCClient`), this drives the app's
/// own Send UI end to end.
@MainActor
final class SuiForwardSyncUITests: XCTestCase {
    private let mnemonic = "test test test test test test test test test test test junk"
    private var app: XCUIApplication!
    private var suiNode: SuiNode!
    private var recipientAddress = ""

    override func setUp() async throws {
        continueAfterFailure = false

        suiNode = try await SuiNode.start()

        let addresses = try await fundSuiAccounts(node: suiNode)
        recipientAddress = addresses[1].string

        app = XCUIApplication(bundleIdentifier: "xyz.reefr.wallet")
        app.launchArguments = [
            "--test",
            "--mnemonic",
            mnemonic,
            "--sui-rpc-url",
            "http://127.0.0.1:\(suiNode.rpcPort)",
            "--create-sui-accounts"
        ]
    }

    override func tearDown() {
        suiNode?.stop()
        suiNode = nil
        app = nil
    }

    // swiftlint:disable:next function_body_length
    func testTransactionSentAfterBackfillIsReceivedByRecipient() {
        app.launch()
        app.activate()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        let firstAccount = app.firstDescendant(withIdentifier: "sidebar-account-label-Testnet #1")
        XCTAssertTrue(firstAccount.waitForExistence(timeout: 20))
        firstAccount.click()

        selectTab("Token Balances")

        let suiRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "balance-row-visible-"))
            .allElementsBoundByIndex
            .first { $0.text.localizedCaseInsensitiveContains("sui") }

        guard let suiRow else {
            XCTFail("Expected a native Sui balance row.")
            return
        }
        suiRow.click()

        let sendButton = app.firstDescendant(withIdentifier: "account-send-button")
        XCTAssertTrue(
            sendButton.waitUntilEnabled(timeout: 10),
            "Expected Send to enable once the SUI row is selected."
        )
        sendButton.click()

        let sentAmount = "0.1"
        let amountField = app.firstDescendant(withIdentifier: "transfer-amount-field")
        XCTAssertTrue(amountField.waitForExistence(timeout: 5))
        amountField.click()
        amountField.typeKey("a", modifierFlags: .command)
        amountField.typeText(sentAmount)

        let receiverField = app.firstDescendant(withIdentifier: "transfer-receiver-field")
        XCTAssertTrue(receiverField.waitForExistence(timeout: 5))
        receiverField.click()
        receiverField.typeText(recipientAddress)

        let nextButton = app.firstDescendant(withIdentifier: "transfer-next-button")
        XCTAssertTrue(
            nextButton.waitUntilEnabled(timeout: 10),
            "Expected Next to enable once the gas simulation for a valid transfer completes."
        )
        nextButton.click()

        let sheetTitle = app.firstDescendant(withIdentifier: "transfer-sheet-title")
        XCTAssertTrue(
            sheetTitle.waitUntilGone(timeout: 5),
            "Expected the Send sheet to dismiss after the transaction was broadcast."
        )

        let secondAccount = app.firstDescendant(withIdentifier: "sidebar-account-label-Testnet #2")
        XCTAssertTrue(secondAccount.waitForExistence(timeout: 10))
        secondAccount.click()

        selectTab("Transactions")

        let hashCell = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "transaction-hash-"))
            .firstMatch
        XCTAssertTrue(
            hashCell.waitForExistence(timeout: 10),
            "Expected the transaction sent after the initial backfill to reach the recipient's list."
        )

        let amountCell = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "transaction-amount-"))
            .firstMatch
        XCTAssertTrue(amountCell.waitForExistence(timeout: 10))
        XCTAssertEqual(
            amountCell.text, "\(sentAmount) SUI",
            "Expected the recipient to receive exactly the amount that was sent."
        )

        let statusCell = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "transaction-status-"))
            .firstMatch
        XCTAssertTrue(statusCell.waitForExistence(timeout: 10))
        XCTAssertEqual(
            statusCell.text, "Confirmed",
            "Expected the checkpointed transaction to be reported as confirmed."
        )
    }
}

private extension SuiForwardSyncUITests {
    func selectTab(_ label: String) {
        let tab = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", label))
            .firstMatch

        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        tab.click()
    }

    func fundSuiAccounts(node: SuiNode) async throws -> [SuiAddress] {
        let seed = try Mnemonic.fromPhrase(mnemonic).toSeed()

        let addresses = try (0 ..< 2).map { index in
            let path = try DerivationPath(string: "m/44'/784'/0'/0'/\(index)'")
            let key = try seed.masterKey(curve: .ed25519).derive(path).privateKey()

            return try SuiPKeySigner(
                curve: .ed25519,
                privateKey: key,
                derivationPath: path
            ).address()
        }

        for address in addresses {
            try await node.faucet(address)
        }

        try await node.waitForSuiCoinCount(of: addresses[0], atLeast: 1)
        try await node.waitForSuiCoinCount(of: addresses[1], atLeast: 1)

        return addresses
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
