import Foundation
import XCTest
import WalletKitTesting

/// Sends a native TRX transfer on Nile from account 0 ("Nile #1") to account 1
/// and checks the recipient's on-chain balance.
///
/// Uses `REEFR_TESTNET_MNEMONIC`; account 0 must hold some Nile TRX.
@MainActor
final class TronTRXTransferUITests: XCTestCase {
    private static let tronGridURL = URL(string: "https://nile.trongrid.io")! // swiftlint:disable:this force_unwrapping
    private let sentAmount = "1"
    private let sentSun: UInt64 = 1_000_000

    private var app: XCUIApplication!
    private var recipientAddress = ""
    private var storeDirectory: URL!

    override func setUp() async throws {
        continueAfterFailure = false
        try requireASCIIKeyboardLayout()

        let environment = ProcessInfo.processInfo.environment
        let mnemonic = environment["REEFR_TESTNET_MNEMONIC"] ?? ""
        try XCTSkipIf(mnemonic.isEmpty, "Set REEFR_TESTNET_MNEMONIC to send on Nile.")

        let path = try DerivationPath(string: "m/44'/195'/0'/0/1")
        let publicKey = try Mnemonic.fromPhrase(mnemonic).toSeed()
            .masterKey(curve: .secp256k1)
            .derive(path)
            .privateKey()
            .publicKey
        recipientAddress = try TronAddress(publicKey: publicKey).string

        storeDirectory = FileManager.default.temporaryDirectory.appending(path: "tron-trx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)

        app = XCUIApplication(bundleIdentifier: "xyz.reefr.wallet")
        app.launchArguments = [
            "--test",
            "--store-path", storeDirectory.appending(path: "keystore.sqlite").path,
            "--mnemonic", mnemonic,
            "--create-tron-accounts"
        ]

        if let apiKey = environment["TRONGRID_API_KEY"], !apiKey.isEmpty {
            app.launchEnvironment["TRONGRID_API_KEY"] = apiKey
        }
    }

    override func tearDown() {
        app?.terminate()
        app = nil

        if let storeDirectory {
            try? FileManager.default.removeItem(at: storeDirectory)
        }
    }

    func testSendsTRXBetweenAccounts() async throws {
        let balanceBefore = try await trxBalance(of: recipientAddress)

        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        let firstAccount = app.firstDescendant(withIdentifier: "sidebar-account-label-Nile #1")
        XCTAssertTrue(firstAccount.waitForExistence(timeout: 20))
        firstAccount.click()

        let tab = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Token Balances"))
            .firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        tab.click()

        let trxRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "balance-row-visible-"))
            .allElementsBoundByIndex
            .first { $0.text.localizedCaseInsensitiveContains("tron") }

        guard let trxRow else {
            XCTFail("Expected a native Tron balance row.")
            return
        }

        trxRow.click()

        let sendButton = app.firstDescendant(withIdentifier: "account-send-button")
        XCTAssertTrue(sendButton.waitUntilEnabled(timeout: 10), "Expected Send to enable for TRX.")
        sendButton.click()

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
        XCTAssertTrue(nextButton.waitUntilEnabled(timeout: 15), "Expected Next to enable after fee estimation.")
        nextButton.click()

        let sheetTitle = app.firstDescendant(withIdentifier: "transfer-sheet-title")
        let dismissed = sheetTitle.waitUntilGone(timeout: 15)
        let sheetTexts = app.sheets.firstMatch.staticTexts.allElementsBoundByIndex.map(\.text)
        XCTAssertTrue(dismissed, "Expected the Send sheet to dismiss after broadcast. Sheet: \(sheetTexts)")

        let expected = balanceBefore + sentSun
        var balanceAfter = balanceBefore
        let deadline = Date.now.addingTimeInterval(60)

        while balanceAfter < expected, Date.now < deadline {
            try await Task.sleep(for: .seconds(3))
            balanceAfter = try await trxBalance(of: recipientAddress)
        }

        XCTAssertGreaterThanOrEqual(balanceAfter, expected, "Expected the recipient's TRX to grow by \(sentAmount).")
    }
}

private extension TronTRXTransferUITests {
    /// Balance in sun; zero for an account that isn't activated yet.
    func trxBalance(of address: String) async throws -> UInt64 {
        var request = URLRequest(url: Self.tronGridURL.appending(path: "wallet/getaccount"))
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["address": address, "visible": true])

        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        return (json?["balance"] as? NSNumber)?.uint64Value ?? 0
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
