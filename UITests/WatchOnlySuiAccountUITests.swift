import Foundation
import XCTest
import WalletKit

/// Verifies that mnemonic-derived Sui accounts display balances from an ephemeral local node.
@MainActor
final class WatchOnlySuiAccountUITests: XCTestCase {
    private let mnemonic = "test test test test test test test test test test test junk"
    private var app: XCUIApplication!
    private var anvilNode: AnvilNode!
    private var suiNode: SuiNode!

    override func setUp() async throws {
        continueAfterFailure = false

        anvilNode = try await AnvilNode.start()
        suiNode = try await SuiNode.start()
        try await fundMnemonicAccounts(node: suiNode)

        app = XCUIApplication(bundleIdentifier: "xyz.reefr.wallet")
        app.launchArguments = [
            "--test",
            "--mnemonic",
            mnemonic,
            "--sui-rpc-url",
            "http://127.0.0.1:\(suiNode.rpcPort)",
            "--evm-rpc-url",
            anvilNode.endpoint.absoluteString
        ]
    }

    override func tearDown() {
        anvilNode?.stop()
        suiNode?.stop()
        anvilNode = nil
        suiNode = nil
        app = nil
    }

    func testMnemonicSuiAccountsDisplayLocalBalances() {
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        for accountNumber in 1 ... 2 {
            let account = app.staticTexts["Sui Testnet #\(accountNumber)"]
            XCTAssertTrue(account.waitForExistence(timeout: 20))
            account.click()

            let updateButton = app.firstDescendant(withIdentifier: "sidebar-update-button")
            XCTAssertTrue(updateButton.waitForExistence(timeout: 10))
            updateButton.click()

            XCTAssertTrue(
                app.staticTexts["Total Value:"].waitForExistence(timeout: 20),
                "Sui Testnet account #\(accountNumber) should display its local-node balance."
            )

            XCTAssertFalse(app.staticTexts["Zero Balances"].exists)
        }
    }

    func testMnemonicSuiAccountDetailsTabsSwitch() {
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        let account = app.staticTexts["Sui Testnet #1"]
        XCTAssertTrue(account.waitForExistence(timeout: 20))
        account.click()

        let transactionsTab = app
            .descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Transactions"))
            .firstMatch
        XCTAssertTrue(transactionsTab.waitForExistence(timeout: 10))
        transactionsTab.click()

        XCTAssertTrue(app.staticTexts["0 Transactions"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Total Value:"].exists)
    }

    private func fundMnemonicAccounts(node: SuiNode) async throws {
        let seed = try Mnemonic.fromPhrase(mnemonic).toSeed()

        for index in 0 ..< 2 {
            let path = try DerivationPath(string: "m/44'/784'/\(index)'/0'/0'")
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
