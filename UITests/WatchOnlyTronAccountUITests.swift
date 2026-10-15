import Foundation
import XCTest

/// Verifies that adding a watch-only Tron mainnet account backfills its
/// TRC-20 token balances and transaction history from live TronGrid data.
@MainActor
final class WatchOnlyTronAccountUITests: XCTestCase {
    private let address = "TLKxBRw8TgeRYanFaML1D4LeVrv2HND22c"
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false

        app = XCUIApplication(bundleIdentifier: "xyz.reefr.wallet")
        app.launchArguments = ["--test"]

        if let apiKey = ProcessInfo.processInfo.environment["TRONGRID_API_KEY"], !apiKey.isEmpty {
            app.launchEnvironment["TRONGRID_API_KEY"] = apiKey
        }
    }

    override func tearDown() {
        app = nil
    }

    func testWatchOnlyMainnetAccountShowsTokenBalancesAndTransactions() {
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        addWatchOnlyTronAccount()

        let account = app.firstDescendant(withIdentifier: "sidebar-account-label-Tron #1")
        XCTAssertTrue(account.waitForExistence(timeout: 20))
        account.click()

        // Allow the descending backfill to fetch history and discover TRC-20 balances.
        sleep(5)

        assertTokenBalances()
        assertTransactions()
    }
}

private extension WatchOnlyTronAccountUITests {
    func addWatchOnlyTronAccount() {
        let addMenu = app.firstDescendant(withIdentifier: "sidebar-add-menu")
        XCTAssertTrue(addMenu.waitForExistence(timeout: 10))
        addMenu.click()

        let watchOnlyItem = app.firstDescendant(withIdentifier: "sidebar-add-watch-only-account-item")
        XCTAssertTrue(watchOnlyItem.waitForExistence(timeout: 10))
        watchOnlyItem.click()

        let blockchainPicker = app.popUpButtons["add-account-blockchain-picker"]
        XCTAssertTrue(blockchainPicker.waitForExistence(timeout: 10))
        blockchainPicker.click()
        app.menuItems["Tron"].click()

        // Tron mainnet is the first entry in the network picker, so selecting
        // the blockchain above already leaves it selected.
        let addressField = app.firstDescendant(withIdentifier: "add-account-watch-address-field")
        XCTAssertTrue(addressField.waitForExistence(timeout: 10))
        addressField.click()
        addressField.typeText(address)

        let submitButton = app.firstDescendant(withIdentifier: "add-account-submit-button")
        XCTAssertTrue(submitButton.waitForExistence(timeout: 10))
        submitButton.click()
    }

    func assertTokenBalances() {
        let balancesTab = app
            .descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Token Balances"))
            .firstMatch
        XCTAssertTrue(balancesTab.waitForExistence(timeout: 10))
        balancesTab.click()

        let balancesContent = app.firstDescendant(withIdentifier: "account-balances-content")
        XCTAssertTrue(
            balancesContent.waitForExistence(timeout: 10),
            "Expected the Tron mainnet watch-only account to display balances."
        )

        let visibleBalances = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "balance-row-visible-"))
        XCTAssertTrue(
            visibleBalances.allElementsBoundByIndex.contains { $0.text.contains("Tron") || $0.text.contains("TRX") },
            "Expected the native TRX balance to appear outside the hidden section."
        )

        let hiddenDisclosure = app.firstDescendant(withIdentifier: "balances-table-hidden-disclosure-row")
        XCTAssertTrue(
            hiddenDisclosure.waitForExistence(timeout: 10),
            "Expected TRC-20 token balances to appear in the Hidden Balances section."
        )

        app.expandHiddenBalances()

        let hiddenBalances = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "balance-row-hidden-"))
        XCTAssertTrue(
            hiddenBalances.count >= 2,
            "Expected a few hidden TRC-20 token balances, found \(hiddenBalances.count)."
        )
    }

    func assertTransactions() {
        let transactionsTab = app
            .descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Transactions"))
            .firstMatch
        XCTAssertTrue(transactionsTab.waitForExistence(timeout: 10))
        transactionsTab.click()

        let transactionCount = app.staticTexts["account-transactions-count"]
        XCTAssertTrue(transactionCount.waitForExistence(timeout: 10))

        let count = Int(transactionCount.text.split(separator: " ").first ?? "") ?? 0
        XCTAssertGreaterThanOrEqual(
            count, 2,
            "Expected a few synced transactions, got: \(transactionCount.text)"
        )
    }
}

private extension XCUIApplication {
    func firstDescendant(withIdentifier identifier: String) -> XCUIElement {
        descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@", identifier))
            .firstMatch
    }
}
