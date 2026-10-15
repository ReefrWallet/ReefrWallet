import BigInt
import Foundation
import XCTest
import WalletKitTesting

/// Regression coverage for the forward-sync gap: a transaction broadcast
/// after the initial backfill completes must still reach the recipient's
/// transaction list without a relaunch.
@MainActor
final class EthereumForwardSyncUITests: XCTestCase {
    private let mnemonic = "test test test test test test test test test test test junk"
    private var app: XCUIApplication!
    private var anvilNode: EthereumNode!
    private var senderAddress = ""
    private var recipientAddress = ""

    override func setUp() async throws {
        continueAfterFailure = false

        anvilNode = try await EthereumNode.start()

        let addresses = try await fundEVMAccounts(node: anvilNode)
        senderAddress = addresses[0].string
        recipientAddress = addresses[1].string

        app = XCUIApplication(bundleIdentifier: "xyz.reefr.wallet")
        app.launchArguments = [
            "--test",
            "--mnemonic",
            mnemonic,
            "--evm-rpc-url",
            anvilNode.endpoint.absoluteString,
            "--create-evm-accounts"
        ]
    }

    override func tearDown() {
        anvilNode?.stop()
        anvilNode = nil
        app = nil
    }

    // swiftlint:disable:next function_body_length
    func testTransactionSentAfterBackfillIsReceivedByRecipient() {
        app.launch()
        app.activate()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        // Both accounts only hold gas: the descending backfill has nothing to
        // page through and completes almost immediately, putting the forward
        // (ascending) track live well before the send below.
        let firstAccount = app.firstDescendant(withIdentifier: "sidebar-account-label-Sepolia #1")
        XCTAssertTrue(firstAccount.waitForExistence(timeout: 20))
        firstAccount.click()

        selectTab("Token Balances")

        let ethRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "balance-row-visible-"))
            .allElementsBoundByIndex
            .first { $0.text.localizedCaseInsensitiveContains("ether") }

        guard let ethRow else {
            XCTFail("Expected a native Ether balance row.")
            return
        }

        ethRow.click()

        let sendButton = app.firstDescendant(withIdentifier: "account-send-button")
        XCTAssertTrue(
            sendButton.waitUntilEnabled(timeout: 10),
            "Expected Send to enable once the ETH row is selected."
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
            nextButton.waitUntilEnabled(timeout: 5),
            "Expected Next to enable once the fee estimate for a valid transfer completes."
        )

        nextButton.click()

        let sheetTitle = app.firstDescendant(withIdentifier: "transfer-sheet-title")
        XCTAssertTrue(
            sheetTitle.waitUntilGone(timeout: 5),
            "Expected the Send sheet to dismiss after the transaction was broadcast."
        )

        let secondAccount = app.firstDescendant(withIdentifier: "sidebar-account-label-Sepolia #2")
        XCTAssertTrue(secondAccount.waitForExistence(timeout: 10))
        secondAccount.click()

        selectTab("Transactions")

        // The recipient's list could in principle hold more than one
        // transaction — match on the sender address rather than assuming
        // the send we just made is the only (or first) row.
        guard let transactionId = waitForTransactionIdentifier(fromSender: senderAddress, timeout: 10) else {
            XCTFail("Expected a transaction from \(senderAddress) to reach the recipient's list.")
            return
        }

        let amountCell = app.firstDescendant(withIdentifier: "transaction-amount-\(transactionId)")
        XCTAssertTrue(amountCell.waitForExistence(timeout: 5))
        XCTAssertEqual(
            amountCell.text, "\(formattedAmount(sentAmount)) ETH",
            "Expected the recipient to receive exactly the amount that was sent."
        )

        sleep(5)

        let statusCell = app.firstDescendant(withIdentifier: "transaction-status-\(transactionId)")
        XCTAssertTrue(statusCell.waitForExistence(timeout: 5))
        XCTAssertEqual(
            statusCell.text, "Confirmed",
            "Expected anvil to have mined the transaction into a block by now."
        )
    }
}

private extension EthereumForwardSyncUITests {
    func selectTab(_ label: String) {
        let tab = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", label))
            .firstMatch

        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        tab.click()
    }

    /// Locates the transaction row whose sender matches `senderAddress`,
    /// polling since the row may not have synced yet, and returns its
    /// identifier suffix (shared by every `transaction-*-<id>` cell in
    /// that row).
    func waitForTransactionIdentifier(fromSender senderAddress: String, timeout: TimeInterval) -> String? {
        let deadline = Date.now.addingTimeInterval(timeout)

        while Date.now < deadline {
            let match = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "transaction-from-"))
                .allElementsBoundByIndex
                .first { $0.text.caseInsensitiveCompare(senderAddress) == .orderedSame }

            if let identifier = match?.identifier {
                return String(identifier.dropFirst("transaction-from-".count))
            }

            _ = app.staticTexts.firstMatch.waitForExistence(timeout: 1)
        }

        return nil
    }

    /// Formats `amount` exactly the way `TransactionAmountLabel` formats a
    /// transaction row's amount, so the expected string matches regardless
    /// of the current locale's decimal separator.
    func formattedAmount(_ amount: String) -> String {
        (Decimal(string: amount) ?? 0).formatted(.number.precision(.fractionLength(0 ... 6)))
    }

    func fundEVMAccounts(node: EthereumNode) async throws -> [EthereumAddress] {
        let seed = try Mnemonic.fromPhrase(mnemonic).toSeed()

        let addresses = try (0 ..< 2).map { index in
            let path = try DerivationPath(string: "m/44'/60'/0'/0/\(index)")
            let key = try seed.masterKey(curve: .secp256k1).derive(path).privateKey()

            return try EthereumPKeySigner(
                chainId: node.chainId,
                privateKey: key,
                derivationPath: path
            ).address()
        }

        for address in addresses {
            try await node.setBalance(address, wei: 10_000_000_000_000_000_000)
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
