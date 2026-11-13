import Foundation
import XCTest

/// Connecting a dapp that injects both an Ethereum and a Solana wallet, against
/// local testnet accounts (see ``UniswapConnectionUITests`` for mainnet): nothing
/// is asked until the page's own connect button is pressed, both chains then
/// share one Connect Request with a drop-down each, and the dapp's entry ends up
/// with a selector per chain.
@MainActor
final class DappConnectionUITests: XCTestCase {
    private let mnemonic = "test test test test test test test test test test test junk"
    private var app: XCUIApplication!
    private var fixtureServer: LocalDappServer!

    override func setUp() async throws {
        continueAfterFailure = false
        try requireASCIIKeyboardLayout()

        fixtureServer = try await LocalDappServer.start(html: multiChainFixtureHTML)

        app = XCUIApplication(bundleIdentifier: "xyz.reefr.wallet")
        app.launchArguments = [
            "--test",
            "-ApplePersistenceIgnoreState", "YES",
            "--mnemonic", mnemonic,
            "--create-evm-accounts",
            "--create-solana-accounts"
        ]
    }

    override func tearDown() {
        fixtureServer?.stop()
        fixtureServer = nil
        app = nil
    }

    func testNothingIsAskedUntilTheDappsConnectButtonIsPressed() {
        openFixture()

        XCTAssertTrue(
            waitForWebText("silent-done", timeout: 10),
            "Expected the page's silent Solana connect to finish."
        )

        XCTAssertTrue(waitForWebText("silent-refused", timeout: 2), "A silent connect must fail instead of prompting.")
        XCTAssertFalse(
            element("dapp-request-title").waitForExistence(timeout: 3),
            "No Connect Request may appear before the page's connect button is pressed."
        )
    }

    func testBothChainsShareOneConnectRequestAndBothGetConfigured() {
        openFixture()
        pressConnectWallet()

        let ethereum = element("dapp-account-picker-ethereum")
        let solana = element("dapp-account-picker-solana")
        XCTAssertTrue(ethereum.waitForExistence(timeout: 10), "Expected an Ethereum drop-down in the Connect Request.")
        XCTAssertTrue(solana.exists, "Expected a Solana drop-down in the same Connect Request.")
        XCTAssertNotEqual(ethereum.frame.minY, solana.frame.minY, "The drop-downs should sit one below another.")

        // Leave Solana "Not connected" and approve.
        choose("Not connected", in: solana)
        XCTAssertTrue(element("dapp-approve-button").isEnabled, "Ethereum is still connected, so Approve is allowed.")
        element("dapp-approve-button").click()

        XCTAssertTrue(waitForWebText("0x", timeout: 10), "Expected the page to receive an Ethereum account.")
        XCTAssertTrue(
            waitForWebText("sol-refused", timeout: 10),
            "Expected the unconnected Solana request to be refused."
        )

        // The dapp's entry offers a selector for each chain, whether or not it is connected.
        let ethereumRow = element("dapp-account-picker-ethereum")
        let solanaRow = element("dapp-account-picker-solana")
        XCTAssertTrue(
            ethereumRow.waitForExistence(timeout: 10),
            "Expected an Ethereum selector in the dapp's settings."
        )

        XCTAssertTrue(solanaRow.exists, "Expected a Solana selector in the dapp's settings.")
        XCTAssertEqual(solanaRow.value as? String, "Not connected")
        XCTAssertNotEqual(ethereumRow.value as? String, "Not connected")

        // Only Ethereum is connected, so the capsule names that account.
        XCTAssertTrue(
            element("browser-account-selector").label.contains("Sepolia"),
            "Expected the capsule to show the connected Ethereum account."
        )
    }

    func testApproveIsDisabledWhileEveryChainIsNotConnected() {
        openFixture()
        pressConnectWallet()

        let ethereum = element("dapp-account-picker-ethereum")
        let solana = element("dapp-account-picker-solana")
        XCTAssertTrue(ethereum.waitForExistence(timeout: 10))
        XCTAssertTrue(element("dapp-approve-button").isEnabled)

        choose("Not connected", in: ethereum)
        XCTAssertTrue(element("dapp-approve-button").isEnabled, "Solana is still connected.")

        choose("Not connected", in: solana)
        XCTAssertFalse(element("dapp-approve-button").isEnabled, "Approve must be disabled with nothing connected.")

        // Picking an account again enables it (item 0 is "Not connected").
        choose(index: 1, in: solana)
        XCTAssertTrue(element("dapp-approve-button").isEnabled)
    }
}

// MARK: - Helpers

private extension DappConnectionUITests {
    func openFixture() {
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        app.openDappInBrowser(fixtureServer.url.absoluteString)
        XCTAssertTrue(
            element("browser-address-field").waitForExistence(timeout: 10),
            "Expected the Browser window to open."
        )
    }

    func pressConnectWallet() {
        let button = app.webViews.firstMatch.buttons["Connect Wallet"]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "Expected the page's Connect Wallet button.")
        button.click()
    }

    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@", identifier))
            .firstMatch
    }

    /// Opens a pop-up button and picks the menu item titled `title`.
    func choose(_ title: String, in popUp: XCUIElement) {
        popUp.click()
        let item = app.menuItems[title].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "Expected a \"\(title)\" item.")
        item.click()
    }

    /// Opens a pop-up button and picks its `index`th menu item.
    func choose(index: Int, in popUp: XCUIElement) {
        popUp.click()
        let item = popUp.menuItems.element(boundBy: index)
        XCTAssertTrue(item.waitForExistence(timeout: 5), "Expected menu item \(index).")
        item.click()
    }

    func waitForWebText(_ text: String, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", text, text)
        let deadline = Date.now.addingTimeInterval(timeout)

        while Date.now < deadline {
            if app.descendants(matching: .any).matching(predicate).firstMatch.waitForExistence(timeout: 0.5) {
                return true
            }
        }

        return false
    }
}

// swiftlint:disable closing_scope_newline

/// A dapp with both an injected `window.ethereum` and a Wallet Standard Solana
/// wallet, like app.uniswap.org: it tries a silent Solana connect on load (a
/// wallet adapter's auto-connect) and connects both chains together when its
/// button is pressed, writing each outcome into the DOM.
private let multiChainFixtureHTML = """
<!DOCTYPE html>
<html>
<head><title>Reefr Multi-chain Dapp Fixture</title></head>
<body>
  <button id="connect">Connect Wallet</button>
  <div id="silent">silent-pending</div>
  <div id="eth">eth-idle</div>
  <div id="sol">sol-idle</div>
  <script>
    const wallets = [];
    const api = { register: (...added) => { wallets.push(...added); return () => {}; } };
    window.addEventListener('wallet-standard:register-wallet', (event) => event.detail(api));
    window.dispatchEvent(new CustomEvent('wallet-standard:app-ready', { detail: api }));

    const solanaWallet = () => wallets.find(
      (wallet) => wallet.features['standard:connect'] && wallet.chains.some((c) => c.startsWith('solana:'))
    );

    async function waitForSolana() {
      for (let attempt = 0; attempt < 40 && !solanaWallet(); attempt++) {
        await new Promise((resolve) => setTimeout(resolve, 250));
      }
      return solanaWallet();
    }

    // What a wallet adapter's auto-connect does on page load.
    (async () => {
      const wallet = await waitForSolana();
      try {
        await wallet.features['standard:connect'].connect({ silent: true });
        document.getElementById('silent').textContent = 'silent-connected';
      } catch (error) {
        document.getElementById('silent').textContent = 'silent-refused';
      }
      document.getElementById('silent').textContent += ' silent-done';
    })();

    document.getElementById('connect').addEventListener('click', async () => {
      const wallet = await waitForSolana();
      await Promise.allSettled([
        window.ethereum.request({ method: 'eth_requestAccounts' }).then(
          (accounts) => { document.getElementById('eth').textContent = accounts[0]; },
          () => { document.getElementById('eth').textContent = 'eth-refused'; }
        ),
        wallet.features['standard:connect'].connect().then(
          (result) => { document.getElementById('sol').textContent = 'sol-' + result.accounts[0].address; },
          () => { document.getElementById('sol').textContent = 'sol-refused'; }
        )
      ]);
    });
  </script>
</body>
</html>
"""

// swiftlint:enable closing_scope_newline
