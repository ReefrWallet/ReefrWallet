import Foundation
import XCTest

/// Verifies that adding a watch-only Cardano mainnet account from an account
/// xpub backfills its ADA and native-asset balances plus its transaction
/// history from live Blockfrost data.
@MainActor
final class WatchOnlyCardanoAccountUITests: XCTestCase {
    /// `m/1852'/1815'/0'` account public key of the funded mainnet account —
    /// the same vector `CardanoMainnetAccount` loads in the service tests.
    /// Cardano watch-only import is xpub-based (see ADR-013), so this is what
    /// the dialog expects rather than an `addr1…` address.
    private let accountXpub = CardanoMainnetAccountVector.load().accountXpub

    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false

        app = XCUIApplication(bundleIdentifier: "xyz.reefr.wallet")
        app.launchArguments = ["--test"]

        if let projectId = blockfrostProjectId {
            app.launchEnvironment["BLOCKFROST_MAINNET_PROJECT_ID"] = projectId
        }
    }

    override func tearDown() {
        app = nil
    }

    func testWatchOnlyMainnetAccountShowsAdaAndNativeAssetBalancesAndTransactions() throws {
        // Blockfrost reads are metered, so this only runs with a project ID.
        try XCTSkipIf(blockfrostProjectId == nil, "BLOCKFROST_MAINNET_PROJECT_ID is not set.")

        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        addWatchOnlyCardanoAccount()

        let account = app.firstDescendant(withIdentifier: "sidebar-account-label-Cardano #1")
        XCTAssertTrue(account.waitForExistence(timeout: 20))
        account.click()

        // Allow the descending backfill to fetch history and the stake
        // account's ADA and native-asset balances.
        sleep(5)

        assertTokenBalances()
        assertTransactions()
    }
}

private extension WatchOnlyCardanoAccountUITests {
    var blockfrostProjectId: String? {
        let projectId = ProcessInfo.processInfo
            .environment["BLOCKFROST_MAINNET_PROJECT_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let projectId, !projectId.isEmpty else {
            return nil
        }

        return projectId
    }

    func addWatchOnlyCardanoAccount() {
        let addMenu = app.firstDescendant(withIdentifier: "sidebar-add-menu")
        XCTAssertTrue(addMenu.waitForExistence(timeout: 10))
        addMenu.click()

        let watchOnlyItem = app.firstDescendant(withIdentifier: "sidebar-add-watch-only-account-item")
        XCTAssertTrue(watchOnlyItem.waitForExistence(timeout: 10))
        watchOnlyItem.click()

        let blockchainPicker = app.popUpButtons["add-account-blockchain-picker"]
        XCTAssertTrue(blockchainPicker.waitForExistence(timeout: 10))
        blockchainPicker.click()
        app.menuItems["Cardano"].click()

        // Cardano mainnet is the first entry in the network picker, so
        // selecting the blockchain above already leaves it selected.
        let xpubField = app.firstDescendant(withIdentifier: "add-account-watch-address-field")
        XCTAssertTrue(xpubField.waitForExistence(timeout: 10))
        xpubField.click()
        xpubField.typeText(accountXpub)

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
            "Expected the Cardano mainnet watch-only account to display balances."
        )

        let visibleBalances = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "balance-row-visible-"))
        XCTAssertTrue(
            visibleBalances.allElementsBoundByIndex.contains { $0.text.localizedCaseInsensitiveContains("ada") },
            "Expected the native ADA balance to appear outside the hidden section."
        )

        // Native assets carry no USD price, so they land in Hidden Balances.
        let hiddenDisclosure = app.firstDescendant(withIdentifier: "balances-table-hidden-disclosure-row")
        XCTAssertTrue(
            hiddenDisclosure.waitForExistence(timeout: 10),
            "Expected native-asset balances to appear in the Hidden Balances section."
        )

        app.expandHiddenBalances()

        let hiddenBalances = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "balance-row-hidden-"))
        XCTAssertTrue(
            hiddenBalances.allElementsBoundByIndex.contains { $0.text.localizedCaseInsensitiveContains("night") },
            "Expected the account's NIGHT balance, found: \(hiddenBalances.allElementsBoundByIndex.map(\.text))"
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

        // "12 Transactions", or "Latest 100 Transactions" once the view's
        // fetch limit is hit — take whichever component is the number.
        let count = transactionCount.text.split(separator: " ").compactMap { Int($0) }.first ?? 0
        XCTAssertGreaterThan(
            count, 0,
            "Expected at least one synced transaction, got: \(transactionCount.text)"
        )
    }
}

/// `TestVectors/cardano-mainnet-account.json` — the account's key and known
/// addresses, kept out of the test sources so the unit and UI test targets
/// share one copy of them.
struct CardanoMainnetAccountVector: Decodable {
    let accountXpub: String
    let addresses: [String]
    let label: String
    let stakeAddress: String

    static func load() -> Self {
        let url = Bundle.module.url(forResource: "cardano-mainnet-account", withExtension: "json")!
        let data = try! Data(contentsOf: url) // swiftlint:disable:this force_try

        return try! JSONDecoder().decode(Self.self, from: data) // swiftlint:disable:this force_try
    }
}

private extension XCUIApplication {
    func firstDescendant(withIdentifier identifier: String) -> XCUIElement {
        descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@", identifier))
            .firstMatch
    }
}
