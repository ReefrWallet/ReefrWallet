import Foundation
import XCTest
import WalletKitTesting

/// Verifies that mnemonic-derived Sui accounts display balances from an ephemeral local node.
@MainActor
final class WatchOnlySuiAccountUITests: XCTestCase {
    private let mnemonic = "test test test test test test test test test test test junk"
    private var app: XCUIApplication!
    private var suiNode: SuiNode!

    override func setUp() async throws {
        continueAfterFailure = false

        suiNode = try await SuiNode.start()
        try await fundMnemonicAccounts(node: suiNode)

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

    func testMnemonicSuiAccountsDisplayLocalBalances() {
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        for accountNumber in 1 ... 2 {
            let account = app.firstDescendant(withIdentifier: "sidebar-account-label-Testnet #\(accountNumber)")
            XCTAssertTrue(account.waitForExistence(timeout: 20))
            account.click()

            let updateButton = app.firstDescendant(withIdentifier: "sidebar-update-button")
            XCTAssertTrue(updateButton.waitForExistence(timeout: 10))
            updateButton.click()

            let balances = app.firstDescendant(withIdentifier: "account-balances-content")
            let zeroBalances = app.firstDescendant(withIdentifier: "account-zero-balances")
            XCTAssertTrue(
                balances.waitForExistence(timeout: 20),
                "Sui Testnet account #\(accountNumber) should display its local-node balance."
            )

            XCTAssertFalse(zeroBalances.exists)
        }
    }

    func testMnemonicSuiAccountDetailsTabsSwitch() {
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        let account = app.firstDescendant(withIdentifier: "sidebar-account-label-Testnet #1")
        XCTAssertTrue(account.waitForExistence(timeout: 20))
        account.click()

        let transactionsTab = app
            .descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Transactions"))
            .firstMatch
        XCTAssertTrue(transactionsTab.waitForExistence(timeout: 10))
        transactionsTab.click()

        // The faucet transfer `setUp` performs is itself account history, and
        // how much of it has synced by now is a race — assert the tab switched,
        // not a particular count.
        let transactionCount = app.staticTexts["account-transactions-count"]
        XCTAssertTrue(transactionCount.waitForExistence(timeout: 10))
        XCTAssertTrue(
            transactionCount.text.hasSuffix(" Transactions"),
            "Expected a transaction count, got: \(transactionCount.text)"
        )

        XCTAssertFalse(app.firstDescendant(withIdentifier: "account-total-value-label").exists)
    }

    private func fundMnemonicAccounts(node: SuiNode) async throws {
        let seed = try Mnemonic.fromPhrase(mnemonic).toSeed()

        for index in 0 ..< 2 {
            let path = try DerivationPath(string: "m/44'/784'/0'/0'/\(index)'")
            let key = try seed.masterKey(curve: .ed25519).derive(path).privateKey()

            let signer = try SuiPKeySigner(
                curve: .ed25519,
                privateKey: key,
                derivationPath: path
            )

            try await node.faucet(try signer.address())
        }
    }
}

private extension XCUIApplication {
    func firstDescendant(withIdentifier identifier: String) -> XCUIElement {
        descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@", identifier))
            .firstMatch
    }
}
