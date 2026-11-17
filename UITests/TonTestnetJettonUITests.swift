import Foundation
import XCTest
import WalletKitTesting

/// Sends a Jetton (RTJ, 6 decimals) on the TON testnet from "Testnet #1" to "Testnet #2" through the Send UI and
/// checks both RTJ balances and both transaction lists.
///
/// Uses `REEFR_TESTNET_MNEMONIC`; account 0 (m/44'/607'/0') needs RTJ (master
/// `kQDDqfCUyXigJ0xBa5m482BBZd56ebMnSIO2OLZVsqtpjF31`) and about 0.25 testnet GRAM for the attachment and fees.
@MainActor
final class TonTestnetJettonUITests: XCTestCase {
    private static let locale = Locale(identifier: "en_US")
    private static let master = "kQDDqfCUyXigJ0xBa5m482BBZd56ebMnSIO2OLZVsqtpjF31"
    /// Random per run (1.000 to 1.500), so this run's transfers stand out from any earlier one.
    private let sent = Decimal(Int.random(in: 1000 ... 1500)) / 1000

    private var app: XCUIApplication!
    private var recipientAddress = ""
    private var senderAddress = ""
    private var storeDirectory: URL!
    private var logPath: URL { storeDirectory.appending(path: "app.log") }

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
            "--create-ton-accounts",
            "--log-path", logPath.path,
            // Pin the formats, so the numbers on screen read the same here as in the app.
            "-AppleLocale", Self.locale.identifier,
            "-AppleLanguages", "(en)"
        ]
    }

    override func tearDown() {
        app?.terminate()
        app = nil

        if let storeDirectory {
            try? FileManager.default.removeItem(at: storeDirectory)
        }
    }

    func testSendsAJettonBetweenAccounts() async throws {
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        // The starting balances come from the chain, for this master, never from a row that may not have loaded.
        let recipientRTJ = try await chainRTJ(of: recipientAddress)
        let senderRTJ = try await chainRTJ(of: senderAddress)
        XCTAssertGreaterThanOrEqual(senderRTJ, sent, "Account 0 needs at least \(sent) RTJ, it holds \(senderRTJ).")

        // The rows already in each account's history are noted once its balances have loaded.
        let recipientRows = loadedTransactionIds(account: "Testnet #2")
        let senderRows = loadedTransactionIds(account: "Testnet #1")
        XCTAssertNotNil(
            waitForBalance("RTJ", timeout: 45) { $0 == senderRTJ },
            "The sender's RTJ row should show \(senderRTJ); now \(shownRTJ())."
        )

        selectTab("Token Balances")
        send(symbol: "RTJ", amount: "\(sent)", to: recipientAddress)

        let senderExpected = senderRTJ - sent
        let senderAfter = waitForBalance("RTJ", timeout: 60, refreshing: true) { $0 == senderExpected }
        XCTAssertEqual(senderAfter, senderExpected, "Expected the sender's RTJ to drop by \(sent); now \(shownRTJ()).")
        selectTab("Transactions")
        XCTAssertTrue(
            waitForNewTransaction(
                excluding: senderRows,
                amount: -sent,
                counterparty: (prefix: "transaction-to-", address: recipientAddress),
                timeout: 60
            ),
            "Expected a new confirmed -\(sent) RTJ transfer to the recipient in the sender's list. \(describeRows(excluding: senderRows))\n\(appLog())"
        )

        openAccount("Testnet #2")
        selectTab("Token Balances")
        let recipientExpected = recipientRTJ + sent
        let recipientAfter = waitForBalance("RTJ", timeout: 60, refreshing: true) { $0 == recipientExpected }
        XCTAssertEqual(recipientAfter, recipientExpected, "Expected the recipient's RTJ to grow by \(sent); now \(shownRTJ()).")
        selectTab("Transactions")
        XCTAssertTrue(
            waitForNewTransaction(
                excluding: recipientRows,
                amount: sent,
                counterparty: (prefix: "transaction-from-", address: senderAddress),
                timeout: 60
            ),
            "Expected a new confirmed \(sent) RTJ transfer from the sender in the recipient's list. \(describeRows(excluding: recipientRows))"
        )
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
        XCTAssertEqual(Self.number(amountField.text), Decimal(string: amount), "The amount field shows \(amountField.text).")

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
            "Expected the Send sheet to dismiss after broadcast. \(dialogState()) \(appLog())"
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

    func openAccount(_ name: String, line: UInt = #line) {
        let account = app.firstDescendant(withIdentifier: "sidebar-account-label-\(name)")
        XCTAssertTrue(account.waitForExistence(timeout: 20), "Expected \(name) in the sidebar.", line: line)
        account.click()
    }

    func selectTab(_ label: String) {
        let tab = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", label))
            .firstMatch

        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        tab.click()
    }

    func shownRTJ() -> String {
        waitForBalance("RTJ", timeout: 5) { _ in true }.map { "\($0)" } ?? "none"
    }

    /// RTJ `address` holds on chain, the same source the app reads.
    func chainRTJ(of address: String) async throws -> Decimal {
        let client = TonClient(network: .testnet, apiKey: ProcessInfo.processInfo.environment["TONCENTER_API_KEY"])
        let raw = try await client.getBalance(client.makeAddress(address), token: Self.master)
        return Decimal(sign: .plus, exponent: -6, significand: Decimal(string: raw.description) ?? 0)
    }

    /// Opens `account`, waits for its balances to load, and returns the ids of its history rows.
    func loadedTransactionIds(account: String) -> Set<String> {
        openAccount(account)
        selectTab("Token Balances")
        XCTAssertNotNil(waitForBalance("GRAM", timeout: 45) { _ in true }, "Balances of \(account) didn't load.")
        return transactionIds(account: account)
    }

    /// Polls `symbol`'s balance row, pressing Update between reads when `refreshing`.
    func waitForBalance(
        _ symbol: String,
        timeout: TimeInterval,
        refreshing: Bool = false,
        where condition: (Decimal) -> Bool
    ) -> Decimal? {
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

    /// The ids of the rows the account's Transactions tab lists now.
    func transactionIds(account: String) -> Set<String> {
        openAccount(account)
        selectTab("Transactions")
        Thread.sleep(forTimeInterval: 3)
        let ids = currentTransactionIds()
        selectTab("Token Balances")
        return ids
    }

    /// A row's marker text; empty when the row doesn't publish it (yet).
    func markerText(_ identifier: String) -> String {
        let element = app.firstDescendant(withIdentifier: identifier)
        return element.exists ? element.text : ""
    }

    /// Whether an error alert is up, and the fee footer, when the Send sheet doesn't close.
    func dialogState() -> String {
        let alert = app.alerts.firstMatch
        let footer = app.firstDescendant(withIdentifier: "transfer-fees-footer")
        return "alert: \(alert.exists ? alert.label : "none"); footer: \(footer.exists ? footer.text : "none")"
    }

    /// What the app logged about TON; the runner can't write elsewhere, so a failure carries it.
    func appLog() -> String {
        guard let log = try? String(contentsOf: logPath, encoding: .utf8) else {
            return "no app log at \(logPath.path)"
        }

        return log.split(separator: "\n")
            .filter { $0.contains("TON") || $0.contains("Jetton") || $0.contains("elivery") || $0.contains("ERROR") }
            .suffix(30).map { String($0.prefix(350)) }.joined(separator: "\n")
    }

    func describeRows(excluding known: Set<String>) -> [String] {
        currentTransactionIds().subtracting(known).map { id in
            ["amount", "status", "from", "to"]
                .map { "\($0)=\(markerText("transaction-\($0)-\(id)"))" }
                .joined(separator: " ")
        }
    }

    func currentTransactionIds() -> Set<String> {
        let prefix = "transaction-amount-"

        return Set(
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
                .allElementsBoundByIndex
                .map { String($0.identifier.dropFirst(prefix.count)) }
        )
    }

    /// Whether the open list has a row that wasn't there before, confirmed, for exactly `amount` RTJ and with
    /// `counterparty` on the given side.
    func waitForNewTransaction(
        excluding known: Set<String>,
        amount: Decimal,
        counterparty: (prefix: String, address: String),
        timeout: TimeInterval
    ) -> Bool {
        let expectedAmount = "\(amount.formatted(.number.locale(Self.locale))) RTJ"
        let expectedAddress = try? TonAddress(string: counterparty.address)
        let deadline = Date.now.addingTimeInterval(timeout)

        while Date.now < deadline {
            for id in currentTransactionIds().subtracting(known) {
                guard markerText("transaction-amount-" + id) == expectedAmount,
                      markerText("transaction-status-" + id) == "Confirmed",
                      let shown = try? TonAddress(string: markerText(counterparty.prefix + id)),
                      shown == expectedAddress
                else {
                    continue
                }

                return true
            }

            // Delivery of a Jetton is checked on each refresh; the row stays unconfirmed until it is known.
            let update = app.firstDescendant(withIdentifier: "sidebar-update-button")

            if update.exists, update.isEnabled {
                update.click()
            }

            Thread.sleep(forTimeInterval: 3)
        }

        return false
    }

    /// A number as the app shows it ("1,235" is one thousand two hundred thirty-five).
    static func number(_ text: String) -> Decimal? {
        let kept = text.filter { $0.isNumber || $0 == "." || $0 == "-" }
        return Decimal(string: kept, locale: Locale(identifier: "en_US"))
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
