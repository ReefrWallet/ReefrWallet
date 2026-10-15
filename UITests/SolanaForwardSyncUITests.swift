import Foundation
import XCTest
import WalletKitTesting

/// Regression coverage for the forward-sync gap: a transaction broadcast
/// after the initial backfill completes must still reach the recipient's
/// transaction list without a relaunch.
@MainActor
final class SolanaForwardSyncUITests: XCTestCase {
    private let mnemonic = "test test test test test test test test test test test junk"
    private var app: XCUIApplication!
    private var senderAddress = ""
    private var solanaNode: SolanaNode!
    private var recipientAddress = ""

    override func setUp() async throws {
        continueAfterFailure = false

        solanaNode = try await SolanaNode.start()

        let addresses = try await fundSolanaAccounts(node: solanaNode)
        senderAddress = addresses[0].string
        recipientAddress = addresses[1].string

        app = XCUIApplication(bundleIdentifier: "xyz.reefr.wallet")
        app.launchArguments = [
            "--test",
            "--mnemonic",
            mnemonic,
            "--solana-rpc-url",
            solanaNode.rpcURL.absoluteString,
            "--create-solana-accounts"
        ]
    }

    override func tearDown() {
        solanaNode?.stop()
        solanaNode = nil
        app = nil
    }

    // swiftlint:disable:next function_body_length
    func testTransactionSentAfterBackfillIsReceivedByRecipient() {
        app.launch()
        app.activate()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        // Let both account histories reach their durable initial boundaries
        // before this test creates the transaction the forward scan must find.
        sleep(20)

        let firstAccount = app.firstDescendant(withIdentifier: "sidebar-account-label-Devnet #1")
        XCTAssertTrue(firstAccount.waitForExistence(timeout: 20))
        firstAccount.click()

        selectTab("Token Balances")

        let solanaRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "balance-row-visible-"))
            .allElementsBoundByIndex
            .first { $0.text.localizedCaseInsensitiveContains("solana") }

        guard let solanaRow else {
            XCTFail("Expected a native Solana balance row.")
            return
        }

        solanaRow.click()

        let sendButton = app.firstDescendant(withIdentifier: "account-send-button")
        XCTAssertTrue(
            sendButton.waitUntilEnabled(timeout: 10),
            "Expected Send to enable once the SOL row is selected."
        )

        sendButton.click()

        let sentAmount = "0.001"
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
            "Expected Next to enable once the fee estimate for a valid transfer completes."
        )

        nextButton.click()

        let sheetTitle = app.firstDescendant(withIdentifier: "transfer-sheet-title")
        XCTAssertTrue(
            sheetTitle.waitUntilGone(timeout: 5),
            "Expected the Send sheet to dismiss after the transaction was broadcast."
        )

        let secondAccount = app.firstDescendant(withIdentifier: "sidebar-account-label-Devnet #2")
        XCTAssertTrue(secondAccount.waitForExistence(timeout: 10))
        secondAccount.click()

        selectTab("Transactions")

        guard let identifier = waitForTransactionIdentifier(from: senderAddress, timeout: 30) else {
            XCTFail("Expected the transaction sent after the initial backfill to reach the recipient's list.")
            return
        }

        let amountCell = app.firstDescendant(withIdentifier: "transaction-amount-\(identifier)")
        XCTAssertTrue(amountCell.waitForExistence(timeout: 10))
        XCTAssertTrue(amountCell.text.hasPrefix(Decimal(string: sentAmount)!.formatted(.number)))
        let statusCell = app.firstDescendant(withIdentifier: "transaction-status-\(identifier)")
        XCTAssertTrue(statusCell.waitForExistence(timeout: 10))
        XCTAssertEqual(
            statusCell.text, "Confirmed",
            "Expected the local validator to have confirmed the transaction by now."
        )
    }
}

private extension SolanaForwardSyncUITests {
    func waitForTransactionIdentifier(from sender: String, timeout: TimeInterval) -> String? {
        let deadline = Date.now.addingTimeInterval(timeout)

        while Date.now < deadline {
            if let cell = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "transaction-from-"))
                .allElementsBoundByIndex
                .first(where: { $0.text.caseInsensitiveCompare(sender) == .orderedSame }) {
                return String(cell.identifier.dropFirst("transaction-from-".count))
            }

            Thread.sleep(forTimeInterval: 1)
        }

        return nil
    }

    func selectTab(_ label: String) {
        let tab = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", label))
            .firstMatch

        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        tab.click()
    }

    func fundSolanaAccounts(node: SolanaNode) async throws -> [SolanaAddress] {
        let seed = try Mnemonic.fromPhrase(mnemonic).toSeed()

        let addresses = try (0 ..< 2).map { index in
            let path = try DerivationPath(string: "m/44'/501'/\(index)'/0'")
            let key = try seed.masterKey(curve: .ed25519).derive(path).privateKey()

            return try SolanaPKeySigner(network: .devnet, privateKey: key, derivationPath: path).address()
        }

        for address in addresses {
            _ = try await node.airdrop(to: address, lamports: 1_000_000_000)
        }

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
