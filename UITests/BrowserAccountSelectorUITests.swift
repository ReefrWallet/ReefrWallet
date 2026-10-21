import Foundation
import XCTest
import WalletKitTesting

/// End-to-end coverage for the unified `[ Key Store ] › [ Blockchain
/// Account ]` browser selector — mirrors `DappBrowserUITests.swift`'s
/// launch-argument/fixture-server conventions. `--create-evm-accounts`
/// and `--create-solana-accounts` both create their 2 test accounts in
/// the same local "Local Key" key store (see `WalletApp.swift`), so
/// these tests only ever exercise the account region; the key-store
/// region is identical `Menu` plumbing, already exercised against real
/// `KeyStoreModel`s by `BrowserAccountSelectionModelTests`.
@MainActor
final class BrowserAccountSelectorUITests: XCTestCase {
    private let mnemonic = "test test test test test test test test test test test junk"
    private var app: XCUIApplication!
    private var anvilNode: EthereumNode!
    private var fixtureServer: DappFixtureServer!
    /// This run's own Browser window — macOS restores previously-open
    /// "Browser" windows across relaunches, so stale windows from
    /// earlier test runs can still be in the accessibility tree.
    /// Scoping every lookup to this one window, rather than searching
    /// the whole app, keeps queries from matching a stale window's
    /// (possibly differently-aged) content instead of this run's.
    private var browserWindow: XCUIElement!

    override func setUp() async throws {
        continueAfterFailure = false
        executionTimeAllowance = 60

        anvilNode = try await EthereumNode.start()
        fixtureServer = try await DappFixtureServer.start()

        app = XCUIApplication(bundleIdentifier: "xyz.reefr.wallet")
        app.launchArguments = [
            "--test",
            "-ApplePersistenceIgnoreState", "YES",
            "--mnemonic", mnemonic,
            "--evm-rpc-url", anvilNode.endpoint.absoluteString,
            "--create-evm-accounts",
            "--create-solana-accounts",
            "--dapp-url", fixtureServer.url.absoluteString
        ]
    }

    override func tearDown() {
        app?.terminate()
        app = nil
        fixtureServer?.stop()
        fixtureServer = nil
        anvilNode?.stop()
        anvilNode = nil
    }

    func testDefaultLabelsAppearAndOldPerNamespacePickersAreAbsent() throws {
        try openBrowser()

        let selector = browserWindow.firstDescendant(withIdentifier: "browser-account-selector")
        XCTAssertTrue(selector.waitForExistence(timeout: 10))

        XCTAssertTrue(waitForSelectedAccount(in: selector, timeout: 10), "Selector label: \(selector.label)")
        XCTAssertTrue(selector.label.contains("Local Key"), "Expected the selector to show its key store.")
        XCTAssertTrue(selector.label.contains("Sepolia #1"), "Expected the selector to show its active account.")

        XCTAssertFalse(browserWindow.firstDescendant(withIdentifier: "browser-ethereum-account-picker").exists)
        XCTAssertFalse(browserWindow.firstDescendant(withIdentifier: "browser-solana-account-picker").exists)
        XCTAssertFalse(browserWindow.firstDescendant(withIdentifier: "browser-sui-account-picker").exists)
    }

    func testSelectingADifferentAccountUpdatesTheSelector() throws {
        try openBrowser()
        connectAndApproveEthereumFixture()
        selectAccount("Sepolia #2")

        let selector = browserWindow.firstDescendant(withIdentifier: "browser-account-selector")
        XCTAssertTrue(
            waitForNativeText(containing: "Sepolia #2", in: selector, timeout: 10),
            "Expected the selector to show the newly selected account."
        )
    }

    func testSwitchingToADifferentChainFamilyDisconnectsThenReconnectsOnSwitchingBack() throws {
        try openBrowser()
        connectAndApproveEthereumFixture()

        selectAccount("Devnet #1")
        XCTAssertTrue(
            waitForWebText(containing: "GONE", timeout: 10),
            "Expected the Ethereum dapp to see a disconnect when the selector moved to a different chain family."
        )

        selectAccount("Sepolia #1")

        // No new approval prompt: Ethereum's grant was never revoked,
        // only reported as inactive while another namespace was selected.
        XCTAssertFalse(
            browserWindow.firstDescendant(withIdentifier: "dapp-approve-button").waitForExistence(timeout: 3),
            "Expected no new connect prompt when switching back to a previously-permitted namespace."
        )

        XCTAssertTrue(
            waitForWebText(containing: "ACTIVE", timeout: 10),
            "Expected the Ethereum dapp to reconnect automatically."
        )
    }
}

// MARK: - Browser/selector actions

private extension BrowserAccountSelectorUITests {
    func openBrowser() throws {
        app.launch()
        app.activate()

        let accountLabel = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "sidebar-account-label-"))
            .firstMatch
        XCTAssertTrue(accountLabel.waitForExistence(timeout: 10), "Expected bootstrapped accounts in the sidebar.")
        app.openDappInBrowser(fixtureServer.url.absoluteString)

        // macOS can restore many stale "Browser" windows from earlier
        // test runs into this same process at launch, and `openWindow`
        // sometimes just re-focuses one of those instead of creating a
        // new one — so window creation order/count isn't a reliable way
        // to find this run's own window. Its fixture URL's port is
        // unique per test (randomly chosen in `DappFixtureServer.start`),
        // so matching on that identifies it regardless of how many
        // stale windows exist.
        let portMarker = ":\(fixtureServer.url.port ?? -1)"
        let browserWindowsQuery = app.windows.containing(.any, identifier: "browser-window")

        let deadline = Date.now.addingTimeInterval(20)
        var matchedWindow: XCUIElement?

        while matchedWindow == nil, Date.now < deadline {
            matchedWindow = browserWindowsQuery.allElementsBoundByIndex.first { window in
                let field = window.firstDescendant(withIdentifier: "browser-address-field")
                return field.exists && (field.value as? String ?? "").contains(portMarker)
            }

            if matchedWindow == nil {
                usleep(200_000)
            }
        }

        browserWindow = try XCTUnwrap(matchedWindow, "Expected a Browser window loaded with this test's fixture URL.")
        let matchedField = browserWindow.firstDescendant(withIdentifier: "browser-address-field")

        XCTAssertTrue(
            matchedField.waitForExistence(timeout: 5),
            "Expected the Browser window address field to remain available."
        )
    }

    func selectAccount(_ name: String) {
        let selector = browserWindow.firstDescendant(withIdentifier: "browser-account-selector")
        XCTAssertTrue(selector.waitForExistence(timeout: 10))
        selector.click()

        let keyStore = app.firstDescendant(withIdentifier: "browser-key-store-menu-item-Local Key")
        XCTAssertTrue(keyStore.waitForExistence(timeout: 10), "Expected the Local Key item.")
        keyStore.click()

        let item = app.firstDescendant(withIdentifier: "browser-account-menu-item-\(name)")
        XCTAssertTrue(item.waitForExistence(timeout: 10), "Expected a \"\(name)\" row in the Local Key list.")
        item.click()
    }

    func connectAndApproveEthereumFixture() {
        XCTAssertTrue(
            waitForWebText(containing: "has-window-ethereum", timeout: 5),
            "Expected the injected provider scripts to define window.ethereum."
        )

        let approveButton = browserWindow.firstDescendant(withIdentifier: "dapp-approve-button")
        XCTAssertTrue(approveButton.waitForExistence(timeout: 10), "Expected the connect approval prompt to appear.")
        approveButton.click()

        XCTAssertTrue(waitForWebText(containing: "ACTIVE", timeout: 10), "Expected the fixture to connect.")
    }
}

// MARK: - Web/native content assertions

private extension BrowserAccountSelectorUITests {
    func waitForSelectedAccount(in selector: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)

        while Date.now < deadline {
            if selector.exists && !selector.label.contains("No Account") {
                return true
            }

            _ = selector.waitForExistence(timeout: 0.5)
        }

        return false
    }

    func waitForWebText(containing text: String, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", text, text)
        return webText(matchingPredicate: predicate, timeout: timeout) != nil
    }

    func webText(matching regex: String, timeout: TimeInterval) -> String? {
        let predicate = NSPredicate(format: "label MATCHES %@ OR value MATCHES %@", regex, regex)
        return webText(matchingPredicate: predicate, timeout: timeout)
    }

    func webText(matchingPredicate predicate: NSPredicate, timeout: TimeInterval) -> String? {
        let deadline = Date.now.addingTimeInterval(timeout)

        while Date.now < deadline {
            let match = browserWindow.descendants(matching: .any).matching(predicate).firstMatch
            if match.waitForExistence(timeout: 0.5) {
                return match.text
            }
        }

        return nil
    }

    /// Like `waitForWebText(containing:)`, but scoped to one native
    /// element (the key-store/account picker buttons) rather than
    /// searching the whole accessibility tree, since their labels are
    /// plain substrings other elements could also momentarily contain.
    func waitForNativeText(containing text: String, in element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)

        while Date.now < deadline {
            if element.text.contains(text) || element.label.contains(text) {
                return true
            }

            _ = element.waitForExistence(timeout: 0.5)
        }

        return false
    }
}

private extension XCUIElement {
    func firstDescendant(withIdentifier identifier: String) -> XCUIElement {
        descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@", identifier))
            .firstMatch
    }
}

// MARK: - DappFixtureServer

/// Serves a single local HTML fixture over plain HTTP (loopback is exempt
/// from ATS) via Python's built-in `http.server` — same technique as
/// `DappBrowserUITests.swift`'s private copy; duplicated rather than
/// shared since each file's fixture HTML differs (this one also listens
/// for `accountsChanged`/`disconnect` events to observe account
/// switches, not just a one-shot connect+sign).
private struct DappFixtureServer {
    let url: URL
    private let process: Process
    private let directory: URL

    static func start() async throws -> DappFixtureServer {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dapp-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try fixtureHTML.write(to: directory.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)

        let port = UInt16.random(in: 52000 ... 52999)
        let process = Process()
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

/// Connects on load, then reflects every `accountsChanged`/`disconnect`
/// event into the DOM — `ACTIVE`/`GONE` rather than `connected`/
/// `disconnected`, so the two states aren't substrings of each other.
private let fixtureHTML = """
<!DOCTYPE html>
<html>
<head><title>Reefr Dapp Fixture</title></head>
<body>
  <div id="status">idle</div>
  <div id="account">NONE</div>
  <div id="connection">PENDING</div>
  <div id="bridge-check">unchecked</div>
  <script>
    document.getElementById('bridge-check').textContent =
      typeof window.ethereum === 'undefined' ? 'no-window-ethereum' : 'has-window-ethereum';

    window.ethereum.on('accountsChanged', function (accounts) {
      if (accounts.length > 0) {
        document.getElementById('account').textContent = accounts[0];
        document.getElementById('connection').textContent = 'ACTIVE';
      } else {
        document.getElementById('account').textContent = 'NONE';
        document.getElementById('connection').textContent = 'GONE';
      }
    });

    window.ethereum.on('disconnect', function () {
      document.getElementById('connection').textContent = 'GONE';
    });

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
        document.getElementById('connection').textContent = 'ACTIVE';
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
