import Foundation
import XCTest
import WalletKitTesting

/// Regression coverage for the forward-sync gap: a transaction broadcast
/// after the initial backfill completes must still reach the recipient's
/// transaction list without a relaunch. Bitcoin regtest, unlike anvil,
/// doesn't auto-mine — the test mines a block itself once the send flow
/// reports the transaction broadcast.
@MainActor
final class BitcoinForwardSyncUITests: XCTestCase {
    private let mnemonic = "test test test test test test test test test test test junk"
    private var app: XCUIApplication!
    private var bitcoinNode: BitcoinNode!
    private var senderAddress = ""
    private var recipientAddress = ""

    override func setUp() async throws {
        continueAfterFailure = false

        bitcoinNode = try await BitcoinNode.start()

        let addresses = try await fundBitcoinAccounts(node: bitcoinNode)
        senderAddress = addresses[0]
        recipientAddress = addresses[1]

        app = XCUIApplication(bundleIdentifier: "xyz.reefr.wallet")
        app.launchArguments = [
            "--test",
            "--mnemonic",
            mnemonic,
            "--bitcoin-rpc-url",
            bitcoinNode.esploraEndpoint.absoluteString,
            "--create-bitcoin-accounts"
        ]
    }

    override func tearDown() {
        bitcoinNode?.stop()
        bitcoinNode = nil
        app = nil
    }

    func testTransactionSentAfterBackfillIsReceivedByRecipient() async throws {
        app.launch()
        app.activate()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        let firstAccount = app.firstDescendant(withIdentifier: "sidebar-account-label-Regtest #1")
        XCTAssertTrue(firstAccount.waitForExistence(timeout: 20))
        firstAccount.click()

        selectTab("Token Balances")

        // Unlike EVM/Solana/Sui's direct RPC balance fetch, Bitcoin's
        // balance comes from an esplora/electrs gap-limit address scan,
        // which lands noticeably later than the tab switch itself.
        guard let bitcoinRow = waitForBalanceRow(containing: "bitcoin", timeout: 30) else {
            XCTFail("Expected a native Bitcoin balance row.")
            return
        }
        bitcoinRow.click()

        let sendButton = app.firstDescendant(withIdentifier: "account-send-button")
        XCTAssertTrue(
            sendButton.waitUntilEnabled(timeout: 10),
            "Expected Send to enable once the BTC row is selected."
        )
        sendButton.click()

        let sentAmount = "0.0001"
        let amountField = app.firstDescendant(withIdentifier: "transfer-amount-field")
        XCTAssertTrue(amountField.waitForExistence(timeout: 5))
        amountField.click()
        amountField.typeKey("a", modifierFlags: .command)
        amountField.typeText(sentAmount)

        let receiverField = app.firstDescendant(withIdentifier: "transfer-receiver-field")
        XCTAssertTrue(receiverField.waitForExistence(timeout: 5))
        receiverField.click()
        receiverField.typeText(recipientAddress)

        // A fresh regtest node has no fee-estimate history, so automatic
        // estimation throws and leaves the rate field empty — type a rate
        // manually, exactly like the WalletKit regtest unit test does via
        // `.bitcoinFeeOverride`.
        let feeRateField = app.firstDescendant(withIdentifier: "transfer-bitcoin-fee-rate-field")
        XCTAssertTrue(feeRateField.waitForExistence(timeout: 5))
        feeRateField.click()
        feeRateField.typeKey("a", modifierFlags: .command)
        feeRateField.typeText("10")

        let nextButton = app.firstDescendant(withIdentifier: "transfer-next-button")
        XCTAssertTrue(
            nextButton.waitUntilEnabled(timeout: 5),
            "Expected Next to enable once a valid fee rate is entered."
        )
        nextButton.click()

        let sheetTitle = app.firstDescendant(withIdentifier: "transfer-sheet-title")
        XCTAssertTrue(
            sheetTitle.waitUntilGone(timeout: 5),
            "Expected the Send sheet to dismiss after the transaction was broadcast."
        )

        // Regtest doesn't auto-mine — mine a block so the broadcast
        // transaction gets a height and the app's next poll reports it
        // confirmed.
        try await bitcoinNode.mine(1, to: try bitcoinNode.newWalletAddress())

        let secondAccount = app.firstDescendant(withIdentifier: "sidebar-account-label-Regtest #2")
        XCTAssertTrue(secondAccount.waitForExistence(timeout: 10))
        secondAccount.click()

        selectTab("Transactions")

        // The recipient was also funded via its own regtest transaction in
        // setUp, so its list holds more than one row — match on the sender
        // address rather than assuming the account-to-account send is the
        // only (or first) one.
        guard let transactionId = waitForTransactionIdentifier(fromSender: senderAddress, timeout: 10) else {
            XCTFail("Expected a transaction from \(senderAddress) to reach the recipient's list.")
            return
        }

        let amountCell = app.firstDescendant(withIdentifier: "transaction-amount-\(transactionId)")
        XCTAssertTrue(amountCell.waitForExistence(timeout: 10))
        XCTAssertEqual(
            amountCell.text, "\(formattedAmount(sentAmount)) BTC",
            "Expected the recipient to receive exactly the amount that was sent."
        )

        let statusCell = app.firstDescendant(withIdentifier: "transaction-status-\(transactionId)")
        XCTAssertTrue(statusCell.waitForExistence(timeout: 10))
        XCTAssertEqual(
            statusCell.text, "Confirmed",
            "Expected the mined block to be reflected as confirmed."
        )
    }
}

private extension BitcoinForwardSyncUITests {
    func selectTab(_ label: String) {
        let tab = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", label))
            .firstMatch

        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        tab.click()
    }

    func waitForBalanceRow(containing substring: String, timeout: TimeInterval) -> XCUIElement? {
        let deadline = Date.now.addingTimeInterval(timeout)

        while Date.now < deadline {
            if let row = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "balance-row-visible-"))
                .allElementsBoundByIndex
                .first(where: { $0.text.localizedCaseInsensitiveContains(substring) }) {
                return row
            }

            _ = app.staticTexts.firstMatch.waitForExistence(timeout: 1)
        }

        return nil
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

    func fundBitcoinAccounts(node: BitcoinNode) async throws -> [String] {
        let seed = try Mnemonic.fromPhrase(mnemonic).toSeed()
        let masterKey = try seed.masterKey(curve: .secp256k1)
        let masterFingerprint = try BitcoinDescriptor.fingerprint(of: masterKey.publicKey)

        let addresses = try (0 ..< 2).map { index -> String in
            let accountPath = try DerivationPath.bitcoinAccount(
                network: .regtest, scriptType: .p2wpkh, accountIndex: UInt32(index)
            )
            let accountKey = try masterKey.derive(accountPath)
            let descriptor = try BitcoinDescriptor(
                xpub: accountKey.serializedPublic(),
                scriptType: .p2wpkh,
                network: .regtest,
                masterFingerprint: masterFingerprint,
                accountPath: String(accountPath.string.dropFirst(2))
            )
            return try descriptor.deriveAddress(chain: 0, index: 0).string()
        }

        for address in addresses {
            _ = try await node.fund(address: address, amountSats: 1_000_000)
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
