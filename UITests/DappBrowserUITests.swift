import BigInt
import Foundation
import XCTest
import WalletKitTesting

/// End-to-end coverage for the dapp bridge: a local HTML fixture calls
/// `window.ethereum.request({method: 'eth_requestAccounts'})` then
/// `personal_sign`, writing both results into the DOM. Approving the
/// resulting connect/sign prompts should let the page read back the
/// connected address and a signature.
@MainActor
final class DappBrowserUITests: XCTestCase {
    private let mnemonic = "test test test test test test test test test test test junk"
    private var app: XCUIApplication!
    private var anvilNode: EthereumNode!
    private var fixtureServer: DappFixtureServer!

    override func setUp() async throws {
        continueAfterFailure = false

        anvilNode = try await EthereumNode.start()
        fixtureServer = try await DappFixtureServer.start()

        app = XCUIApplication(bundleIdentifier: "xyz.reefr.wallet")
        app.launchArguments = [
            "--test",
            "-ApplePersistenceIgnoreState", "YES",
            "--mnemonic", mnemonic,
            "--evm-rpc-url", anvilNode.endpoint.absoluteString,
            "--create-evm-accounts",
            "--dapp-url", fixtureServer.url.absoluteString
        ]
    }

    override func tearDown() {
        fixtureServer?.stop()
        fixtureServer = nil
        anvilNode?.stop()
        anvilNode = nil
        app = nil
    }

    func testConnectingAndSigningWritesResultsIntoTheFixturesDOM() throws {
        app.launch()
        app.activate()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        app.openDappInBrowser(fixtureServer.url.absoluteString)

        let addressField = app.firstDescendant(withIdentifier: "browser-address-field")
        XCTAssertTrue(addressField.waitForExistence(timeout: 10), "Expected the Browser window to open.")

        XCTAssertTrue(
            waitForWebText(containing: "has-window-ethereum", timeout: 5),
            "Expected the injected bridge/provider scripts to define window.ethereum before the page's own script runs."
        )

        // The connect prompt (from the fixture's own `eth_requestAccounts`
        // retry loop) appears once the browser window's account picker has
        // a default Ethereum account selected.
        let approveButton = app.firstDescendant(withIdentifier: "dapp-approve-button")
        XCTAssertTrue(approveButton.waitForExistence(timeout: 10), "Expected the connect approval prompt to appear.")
        approveButton.click()

        // Approve the subsequent personal_sign prompt.
        let secondApproveButton = app.firstDescendant(withIdentifier: "dapp-approve-button")
        XCTAssertTrue(secondApproveButton.waitForExistence(timeout: 10), "Expected the sign approval prompt to appear.")
        secondApproveButton.click()

        XCTAssertTrue(
            waitForWebText(containing: "done", timeout: 10),
            "Expected the fixture page to report status \"done\" after connecting and signing."
        )

        XCTAssertTrue(
            waitForWebText(matching: "0x[0-9a-fA-F]{40}", timeout: 5),
            "Expected the fixture page to display the connected account's address."
        )

        XCTAssertTrue(
            waitForWebText(matching: "0x[0-9a-fA-F]{130}", timeout: 5),
            "Expected the fixture page to display a 65-byte personal_sign signature."
        )
    }
}

// MARK: - Web content assertions

private extension DappBrowserUITests {
    func waitForWebText(containing text: String, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", text, text)
        return waitForWebText(matchingPredicate: predicate, timeout: timeout)
    }

    func waitForWebText(matching regex: String, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "label MATCHES %@ OR value MATCHES %@", regex, regex)
        return waitForWebText(matchingPredicate: predicate, timeout: timeout)
    }

    func waitForWebText(matchingPredicate predicate: NSPredicate, timeout: TimeInterval) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)

        while Date.now < deadline {
            let match = app.descendants(matching: .any).matching(predicate).firstMatch
            if match.waitForExistence(timeout: 0.5) {
                return true
            }
        }

        return false
    }
}

private extension XCUIApplication {
    func firstDescendant(withIdentifier identifier: String) -> XCUIElement {
        descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@", identifier))
            .firstMatch
    }
}

// MARK: - DappFixtureServer

/// Serves a single local HTML fixture over plain HTTP (loopback is exempt
/// from ATS) via Python's built-in `http.server` — a static file server,
/// so no new production networking code is needed just for this test.
private struct DappFixtureServer {
    let url: URL
    private let process: Process
    private let directory: URL

    static func start() async throws -> DappFixtureServer {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dapp-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try fixtureHTML.write(to: directory.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)

        let port = UInt16.random(in: 51000 ... 51999)
        let process = Process()
        // Homebrew's real Python binary, not `/usr/bin/python3` — that
        // one is an `xcrun`-dispatching shim (Command Line Tools), and
        // `xcrun` refuses to run at all inside the UI test runner's App
        // Sandbox ("xcrun: error: cannot be used within an App
        // Sandbox."). The absolute path also sidesteps needing `env` to
        // resolve `python3` through a `PATH` the sandboxed runner may
        // not share.
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/python3")
        process.arguments = ["-m", "http.server", String(port), "--bind", "127.0.0.1", "--directory", directory.path]
        process.currentDirectoryURL = directory
        let logURL = directory.appendingPathComponent("server.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)
        process.standardOutput = logHandle
        process.standardError = logHandle
        try process.run()

        let url = URL(string: "http://127.0.0.1:\(port)/index.html")! // swiftlint:disable:this force_unwrapping
        do {
            try await waitUntilReady(url: url)
        } catch {
            let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? "(no log)"
            throw NSError(domain: "DappFixtureServer", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "\(error) — isRunning=\(process.isRunning), log:\n\(log)"
            ])
        }

        return DappFixtureServer(url: url, process: process, directory: directory)
    }

    func stop() {
        process.terminate()
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: directory)
    }

    /// Polls asynchronously (never blocking the run loop) — a UI test's
    /// `setUp()` runs early in the runner process's life, and blocking
    /// it synchronously here can starve XCTest's own automation-mode
    /// handshake.
    private static func waitUntilReady(url: URL) async throws {
        let deadline = Date.now.addingTimeInterval(10)
        var lastError: Error?

        while Date.now < deadline {
            do {
                let (_, response) = try await URLSession.shared.data(from: url)
                if (response as? HTTPURLResponse)?.statusCode == 200 {
                    return
                }
            } catch {
                lastError = error
            }

            try? await Task.sleep(for: .milliseconds(200))
        }

        throw lastError ?? NSError(domain: "DappFixtureServer", code: -1, userInfo: [
            NSLocalizedDescriptionKey: "fixture server at \(url) never became ready"
        ])
    }
}

// swiftlint:disable closing_scope_newline

/// Calls `eth_requestAccounts` then `personal_sign`, retrying
/// `eth_requestAccounts` for a few seconds in case the browser's account
/// picker hasn't selected a default Ethereum account yet, and writes
/// every result into the DOM for the UI test to read back.
private let fixtureHTML = """
<!DOCTYPE html>
<html>
<head><title>Reefr Dapp Fixture</title></head>
<body>
  <div id="status">idle</div>
  <div id="account"></div>
  <div id="signature"></div>
  <div id="bridge-check">unchecked</div>
  <script>
    document.getElementById('bridge-check').textContent =
      typeof window.ethereum === 'undefined' ? 'no-window-ethereum' : 'has-window-ethereum';

    async function requestAccountsWithRetry() {
      for (let attempt = 0; attempt < 30; attempt++) {
        try {
          return await window.ethereum.request({ method: 'eth_requestAccounts' });
        } catch (error) {
          document.getElementById('status').textContent = 'retrying: ' + error.message;
          await new Promise((resolve) => setTimeout(resolve, 500));
        }
      }
      throw new Error('gave up waiting for an Ethereum account');
    }

    async function run() {
      try {
        const accounts = await requestAccountsWithRetry();
        document.getElementById('account').textContent = accounts[0];

        const signature = await window.ethereum.request({
          method: 'personal_sign',
          params: ['0x48656c6c6f2c20526565667221', accounts[0]]
        });
        document.getElementById('signature').textContent = signature;
        document.getElementById('status').textContent = 'done';
      } catch (error) {
        document.getElementById('status').textContent = 'error: ' + error.message;
      }
    }

    run();
  </script>
</body>
</html>
"""

// swiftlint:enable closing_scope_newline
