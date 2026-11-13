import Foundation
import XCTest
import WalletKitTesting

/// Sends a TRC-20 USDT transfer on Nile from account 0 ("Nile #1") to account 1
/// and checks the recipient's on-chain balance.
///
/// Uses `REEFR_TESTNET_MNEMONIC`; account 0 must hold Nile USDT and some TRX.
@MainActor
final class TronUSDTTransferUITests: XCTestCase {
    private static let tronGridURL = URL(string: "https://nile.trongrid.io")! // swiftlint:disable:this force_unwrapping
    private static let usdtAddress = "TXYZopYRdj2D9XRtbG411XZZ3kM5VkAeBf"
    private let sentAmount = "0.01"

    private var app: XCUIApplication!
    private var mnemonic = ""
    private var recipientAddress = ""
    private var senderAddress = ""
    private var storeDirectory: URL!

    override func setUp() async throws {
        continueAfterFailure = false
        try requireASCIIKeyboardLayout()

        let environment = ProcessInfo.processInfo.environment
        mnemonic = environment["REEFR_TESTNET_MNEMONIC"] ?? ""
        try XCTSkipIf(mnemonic.isEmpty, "Set REEFR_TESTNET_MNEMONIC to send on Nile.")

        let seed = try Mnemonic.fromPhrase(mnemonic).toSeed()
        let addresses = try (0 ..< 2).map { index in
            let path = try DerivationPath(string: "m/44'/195'/0'/0/\(index)")
            let publicKey = try seed.masterKey(curve: .secp256k1).derive(path).privateKey().publicKey

            return try TronAddress(publicKey: publicKey).string
        }

        senderAddress = addresses[0]
        recipientAddress = addresses[1]

        storeDirectory = FileManager.default.temporaryDirectory.appending(path: "tron-usdt-\(UUID().uuidString)")
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

    // swiftlint:disable:next function_body_length
    func testSendsUSDTBetweenAccounts() async throws {
        let balanceBefore = try await usdtBalance(of: recipientAddress)

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

        func findUSDTRow() -> XCUIElement? {
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "balance-row-"))
                .allElementsBoundByIndex
                .first { $0.text.contains("USDT") || $0.text.contains("Tether") }
        }

        let updateButton = app.firstDescendant(withIdentifier: "sidebar-update-button")

        if updateButton.waitUntilEnabled(timeout: 10) {
            updateButton.click()
        }

        var usdtRow = findUSDTRow()
        let rowDeadline = Date.now.addingTimeInterval(90)

        while usdtRow == nil, Date.now < rowDeadline {
            try await Task.sleep(for: .seconds(2))

            usdtRow = findUSDTRow()
        }

        guard let usdtRow else {
            let senderBalance = (try? await usdtBalance(of: senderAddress)) ?? 0
            let rows = app.descendants(matching: .any)
                .matching(NSPredicate(
                    format: "identifier BEGINSWITH %@ OR identifier BEGINSWITH %@",
                    "balance-",
                    "balances-"
                ))
                .allElementsBoundByIndex
                .map { "\($0.identifier)=\($0.text)" }
            XCTFail("Expected a visible USDT balance row. Rows: \(rows). Sender \(senderAddress) USDT on-chain: \(senderBalance); recipient: \(balanceBefore)")
            return
        }

        usdtRow.click()

        let sendButton = app.firstDescendant(withIdentifier: "account-send-button")
        XCTAssertTrue(sendButton.waitUntilEnabled(timeout: 10), "Expected Send to enable for USDT.")
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
        XCTAssertTrue(sheetTitle.waitUntilGone(timeout: 15), "Expected the Send sheet to dismiss after broadcast.")

        let expected = balanceBefore + 10_000
        var balanceAfter = balanceBefore
        let deadline = Date.now.addingTimeInterval(60)

        while balanceAfter < expected, Date.now < deadline {
            try await Task.sleep(for: .seconds(3))
            balanceAfter = try await usdtBalance(of: recipientAddress)
        }

        XCTAssertGreaterThanOrEqual(balanceAfter, expected, "Expected the recipient's USDT to grow by \(sentAmount).")
    }
}

private extension TronUSDTTransferUITests {
    /// `balanceOf(address)` in base units, via a constant contract call.
    func usdtBalance(of address: String) async throws -> UInt64 {
        let raw = try TronAddress(string: address).rawBytes.dropFirst().map { String(format: "%02x", $0) }.joined()
        var request = URLRequest(url: Self.tronGridURL.appending(path: "wallet/triggerconstantcontract"))
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "owner_address": address,
            "contract_address": Self.usdtAddress,
            "function_selector": "balanceOf(address)",
            "parameter": String(repeating: "0", count: 24) + raw,
            "visible": true
        ])

        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let hex = (json?["constant_result"] as? [String])?.first ?? "0"

        return UInt64(hex.suffix(16), radix: 16) ?? 0
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
