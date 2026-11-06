import Foundation
import WalletKit
import WalletKitTesting
import XCTest

/// Stakes, unstakes in part and withdraws through the Solana Staking tab against a local
/// validator with short epochs, using a software key.
@MainActor
final class SolanaStakingUITests: XCTestCase {
    private let mnemonic = "test test test test test test test test test test test junk"
    private var app: XCUIApplication!
    private var solanaNode: SolanaNode!

    override func setUp() async throws {
        continueAfterFailure = false

        solanaNode = try await SolanaNode.start(slotsPerEpoch: 32)

        let seed = try Mnemonic.fromPhrase(mnemonic).toSeed()
        let path = try DerivationPath(string: "m/44'/501'/0'/0'")
        let key = try seed.masterKey(curve: .ed25519).derive(path).privateKey()
        let address = try SolanaPKeySigner(network: .devnet, privateKey: key, derivationPath: path).address()

        _ = try await solanaNode.airdrop(to: address, lamports: 20_000_000_000)

        app = XCUIApplication(bundleIdentifier: "xyz.reefr.wallet")
        app.launchArguments = [
            "--test",
            "--mnemonic",
            mnemonic,
            "--solana-rpc-url",
            solanaNode.rpcURL.absoluteString,
            "--create-solana-accounts"
        ]
    }

    override func tearDown() {
        solanaNode?.stop()
        solanaNode = nil
        app = nil
    }

    func testStakeUnstakeWithdraw() {
        app.launch()
        app.activate()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        let account = app.firstDescendant(withIdentifier: "sidebar-account-label-Devnet #1")
        XCTAssertTrue(account.waitForExistence(timeout: 20))
        account.click()

        let tab = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Staking")).firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        tab.click()

        let staked = app.firstDescendant(withIdentifier: "staking-staked")
        XCTAssertTrue(staked.waitForExistence(timeout: 20), "Expected the summary once the position is read.")

        // Stake: the best validator is preselected, so an amount completes it.
        let stake = app.firstDescendant(withIdentifier: "staking-stake-button")
        XCTAssertTrue(stake.waitUntilEnabled(timeout: 10))
        stake.click()

        let amount = app.firstDescendant(withIdentifier: "staking-amount-field")
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        amount.click()
        amount.typeText("3")

        let next = app.firstDescendant(withIdentifier: "staking-next-button")
        let title = app.firstDescendant(withIdentifier: "staking-sheet-title")
        sendUntilClosed(next: next, title: title)

        // Warmup finishes within a few short epochs.
        XCTAssertTrue(
            app.staticTexts["Active"].waitForExistence(timeout: 60),
            "Expected the stake account to activate."
        )

        // Partial unstake: one account selected, a smaller amount.
        let unstake = app.firstDescendant(withIdentifier: "staking-unstake-button")
        XCTAssertTrue(unstake.waitUntilEnabled(timeout: 10))
        unstake.click()

        let partial = app.firstDescendant(withIdentifier: "staking-amount-field")
        XCTAssertTrue(partial.waitForExistence(timeout: 10))
        partial.click()
        partial.typeKey("a", modifierFlags: .command)
        partial.typeText("1")

        sendUntilClosed(next: next, title: title)

        // Withdraw what cooled down.
        let withdraw = app.buttons["Withdraw"]
        XCTAssertTrue(withdraw.waitForExistence(timeout: 90), "Expected Ready to Withdraw after cooldown.")
        withdraw.click()

        sendUntilClosed(next: next, title: title)
        XCTAssertTrue(withdraw.waitUntilGone(timeout: 30), "Expected the section to go once withdrawn.")
    }

    /// Presses Next until the sheet closes. With 32-slot epochs, reward payout (when the program
    /// refuses stake changes) comes around often, and the sheet then reports it and stays open.
    private func sendUntilClosed(next: XCUIElement, title: XCUIElement) {
        for _ in 0..<12 {
            let ok = app.buttons["OK"]

            if ok.exists {
                ok.click()
            }

            if next.waitUntilEnabled(timeout: 5) {
                next.click()
            }

            if title.waitUntilGone(timeout: 15) {
                return
            }
        }

        let texts = app.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | ")
        XCTFail("The sheet never closed: \(texts)")
    }
}

private extension XCUIApplication {
    func firstDescendant(withIdentifier identifier: String) -> XCUIElement {
        descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}

private extension XCUIElement {
    func waitUntilEnabled(timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == true AND isEnabled == true")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    func waitUntilGone(timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: self)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
