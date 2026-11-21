#if os(iOS)
import Foundation
import XCTest

/// iPhone: an EVM account has an NFTs chip that opens the NFTs tab.
final class NFTsTabIOSUITests: XCTestCase {
    private var app: XCUIApplication!
    private var storeDirectory: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false

        storeDirectory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)

        app = XCUIApplication(bundleIdentifier: "xyz.reefr.wallet")
        app.launchArguments = [
            "--test",
            "--store-path", storeDirectory.appending(path: "wallet.sqlite").path,
            "--disable-transaction-sync",
            "--disable-price-updates",
            "--mnemonic", "test test test test test test test test test test test junk",
            "--create-evm-accounts"
        ]
    }

    override func tearDown() {
        app?.terminate()
        try? FileManager.default.removeItem(at: storeDirectory)
        app = nil
    }

    func testEVMAccountShowsNFTsTab() {
        app.launch()

        // iPhone account rows carry no identifier; find the row by its name.
        let account = app.staticTexts["Sepolia #1"]
        XCTAssertTrue(account.waitForExistence(timeout: 20))
        account.tap()

        let chip = element("account-tab-nfts")
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "Expected an NFTs chip on an EVM account.")
        chip.tap()

        // A fresh account owns nothing; offline, the tab still settles on its empty state.
        XCTAssertTrue(element("account-no-nfts").waitForExistence(timeout: 30), "Expected the NFTs tab's empty state.")
        XCTAssertEqual(element("account-nfts-count").label, "No NFTs")
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@", identifier))
            .firstMatch
    }
}
#endif
