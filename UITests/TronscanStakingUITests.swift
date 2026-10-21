import Foundation
import XCTest

/// Stakes TRX for bandwidth and for energy through Nile Tronscan's Stake 2.0
/// flow (`/sr/wallet-stake-home` → Stake Now → Get Bandwidth/Energy),
/// approving the TronLink-compatible connect and `FreezeBalanceV2Contract`
/// signing prompts, then checks the account's `frozenV2` on Nile TronGrid.
///
/// Uses account 0 ("Nile #1") of `REEFR_TESTNET_MNEMONIC`, which must hold a
/// few TRX on Nile. Each run stakes ``stakeAmountTRX`` per resource.
///
/// Nile Tronscan rather than `tronscan.org`: the mainnet site stakes against
/// mainnet and sits behind a Cloudflare bot check.
@MainActor
final class TronscanStakingUITests: XCTestCase {
    fileprivate enum Resource: String {
        case bandwidth = "BANDWIDTH"
        case energy = "ENERGY"

        var getButtonLabel: String {
            switch self {
            case .bandwidth: "Get Bandwidth"
            case .energy: "Get Energy"
            }
        }

        var optionLabel: String {
            switch self {
            case .bandwidth: "Bandwidth + TRON Power"
            case .energy: "Energy + TRON Power"
            }
        }

        var previewLabel: String {
            switch self {
            case .bandwidth: "Bandwidth"
            case .energy: "Energy"
            }
        }
    }

    private static let stakeHomeURL = "https://nile.tronscan.org/#/sr/wallet-stake-home"
    private static let tronGridURL = URL(string: "https://nile.trongrid.io")! // swiftlint:disable:this force_unwrapping
    private let stakeAmountTRX = 1

    private var app: XCUIApplication!
    private var storeDirectory: URL!

    override func setUp() async throws {
        continueAfterFailure = false

        let environment = ProcessInfo.processInfo.environment
        let mnemonic = environment["REEFR_TESTNET_MNEMONIC"] ?? ""
        try XCTSkipIf(mnemonic.isEmpty, "Set REEFR_TESTNET_MNEMONIC to stake on Nile.")

        storeDirectory = FileManager.default.temporaryDirectory.appending(path: "tron-staking-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)

        app = XCUIApplication(bundleIdentifier: "xyz.reefr.wallet")
        app.launchArguments = [
            "--test",
            "-ApplePersistenceIgnoreState", "YES",
            "--store-path", storeDirectory.appending(path: "keystore.sqlite").path,
            "--mnemonic", mnemonic,
            "--create-tron-accounts",
            "--dapp-url", Self.stakeHomeURL
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

    func testStakingForBandwidth() async throws {
        try await stake(for: .bandwidth)
    }

    func testStakingForEnergy() async throws {
        try await stake(for: .energy)
    }
}

// MARK: - Flow

private extension TronscanStakingUITests {
    func stake(for resource: Resource) async throws {
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        openFreshBrowser()

        let address = connectWallet()
        let frozenBefore = try await frozenBalance(of: address, resource: resource)

        openStakeDialog(for: resource)
        submitStake(for: resource)
        approveStake(for: resource)

        let expected = frozenBefore + UInt64(stakeAmountTRX) * 1_000_000
        let frozenAfter = try await waitForFrozenBalance(
            of: address,
            resource: resource,
            atLeast: expected,
            timeout: 30
        )

        XCTAssertGreaterThanOrEqual(
            frozenAfter,
            expected,
            "Expected \(address)'s staked \(resource.rawValue) to grow by \(stakeAmountTRX) TRX."
        )
    }

    /// Opens the only Browser window at the Stake page.
    func openFreshBrowser() {
        app.openDappInBrowser(Self.stakeHomeURL)
        XCTAssertTrue(
            app.firstDescendant(withIdentifier: "browser-address-field").waitForExistence(timeout: 10),
            "Expected the Browser window to open."
        )
    }

    /// Connects through Tronscan's TronLink option and returns the
    /// approved account's address, read from the connect prompt.
    func connectWallet() -> String {
        let connectWallet = webElement(labelBeginsWith: "Connect Wallet")
        XCTAssertTrue(
            connectWallet.waitForExistence(timeout: 10),
            "Expected Tronscan's Connect Wallet button. \(diagnostics(matching: "Connect"))"
        )

        dismissCookieBanner()
        connectWallet.click()

        let connect = web.buttons["Connect"]
        XCTAssertTrue(connect.waitForExistence(timeout: 10), "Expected Tronscan's connection method dialog.")
        connect.click()

        let approve = app.firstDescendant(withIdentifier: "dapp-approve-button")
        XCTAssertTrue(approve.waitForExistence(timeout: 10), "Expected Reefr's connect prompt.")

        // Read the address from Reefr's own prompt, not the page.
        let sheet = app.sheets.firstMatch
        let tronAddress = "T[1-9A-HJ-NP-Za-km-z]{33}"
        let addressText = sheet.staticTexts
            .matching(NSPredicate(format: "label MATCHES %@ OR value MATCHES %@", ".*\(tronAddress).*", ".*\(tronAddress).*"))
            .firstMatch
        XCTAssertTrue(addressText.waitForExistence(timeout: 5), "Expected the connect prompt to show the Tron address.")
        let promptText = addressText.text
        let address = promptText
            .range(of: tronAddress, options: .regularExpression)
            .map { String(promptText[$0]) } ?? ""

        let accountName = sheet.staticTexts
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Nile #1", "Nile #1"))
        XCTAssertTrue(accountName.firstMatch.exists, "Expected Nile #1 (account 0) to be the connected account.")
        approve.click()

        let connected = webElement(labelBeginsWith: String(address.prefix(6)))
        XCTAssertTrue(connected.waitForExistence(timeout: 10), "Expected Tronscan to show \(address) as connected.")
        return address
    }

    func openStakeDialog(for resource: Resource) {
        let stakeNow = webElement(labelBeginsWith: "Stake Now")
        XCTAssertTrue(stakeNow.waitForExistence(timeout: 10), "Expected Tronscan's Stake Now link.")
        scrollIntoView(stakeNow)
        stakeNow.click()

        let getResource = webElement(labelBeginsWith: resource.getButtonLabel)
        XCTAssertTrue(getResource.waitForExistence(timeout: 10), "Expected \(resource.getButtonLabel) on the Stake 2.0 page.")
        scrollIntoView(getResource)
        getResource.click()
    }

    func submitStake(for resource: Resource) {
        let option = web.radioButtons[resource.optionLabel]
        XCTAssertTrue(option.waitForExistence(timeout: 10), "Expected Tronscan's stake dialog.")
        option.click()

        let amount = web.textFields
            .matching(NSPredicate(format: "placeholderValue CONTAINS[c] %@", "amount you want to stake"))
            .firstMatch
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        amount.click()
        amount.typeText(String(stakeAmountTRX))

        let confirm = web.buttons["Confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil(timeout: 5) { confirm.isEnabled }, "Expected Confirm to enable for \(stakeAmountTRX) TRX.")
        confirm.click()
    }

    /// Checks Reefr's decoded preview, then approves the signature.
    func approveStake(for resource: Resource) {
        let approve = app.firstDescendant(withIdentifier: "dapp-approve-button")
        XCTAssertTrue(
            approve.waitForExistence(timeout: 10),
            "Expected Reefr's signing prompt; a decoding failure would show an error instead."
        )

        for text in ["Stake TRX", "\(stakeAmountTRX) TRX", resource.previewLabel] {
            XCTAssertTrue(
                app.staticTexts
                    .matching(NSPredicate(format: "label == %@ OR value == %@", text, text))
                    .firstMatch
                    .exists,
                "Expected the signing prompt to show \"\(text)\"."
            )
        }

        approve.click()
    }
}

// MARK: - Web content

private extension TronscanStakingUITests {
    var web: XCUIElement {
        app.webViews.firstMatch
    }

    func webElement(labelBeginsWith prefix: String) -> XCUIElement {
        web.descendants(matching: .any)
            // Web text publishes its content as the AX value, not the label.
            .matching(NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@", prefix, prefix))
            .firstMatch
    }

    /// Every element whose label or value mentions `text`, for failure messages.
    func diagnostics(matching text: String) -> String {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", text, text))
            .allElementsBoundByIndex
            .prefix(10)
            .map { "[\($0.elementType.rawValue) label=\($0.label) value=\($0.value ?? "")]" }
            .joined(separator: " ")
    }

    func dismissCookieBanner() {
        let gotIt = webElement(labelBeginsWith: "Got It")
        if gotIt.waitForExistence(timeout: 2), gotIt.isHittable {
            gotIt.click()
        }
    }

    /// Scrolls the page until `element` sits fully inside the web view
    /// (web elements rarely report `isHittable`, so use frames).
    func scrollIntoView(_ element: XCUIElement, attempts: Int = 20) {
        func isVisible() -> Bool {
            let viewport = web.frame.insetBy(dx: 0, dy: 40)
            return viewport.contains(element.frame)
        }

        for _ in 0 ..< attempts where !isVisible() {
            let direction: CGFloat = element.frame.midY > web.frame.midY ? -1 : 1
            web.scroll(byDeltaX: 0, deltaY: direction * 200)
        }

        XCTAssertTrue(isVisible(), "Couldn't scroll \(element.text) into view.")
    }

    func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)

        while Date.now < deadline {
            if condition() {
                return true
            }

            RunLoop.current.run(until: .now.addingTimeInterval(0.25))
        }

        return condition()
    }
}

// MARK: - TronGrid

private extension TronscanStakingUITests {
    /// The SUN `address` has staked for `resource` (Stake 2.0 `frozenV2`;
    /// java-tron omits `type` for BANDWIDTH and `amount` for zero).
    func frozenBalance(of address: String, resource: Resource) async throws -> UInt64 {
        var request = URLRequest(url: Self.tronGridURL.appending(path: "wallet/getaccount"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["address": address, "visible": true])

        let (data, _) = try await URLSession.shared.data(for: request)
        let account = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let frozen = account["frozenV2"] as? [[String: Any]] ?? []

        return frozen
            .filter { ($0["type"] as? String ?? Resource.bandwidth.rawValue) == resource.rawValue }
            .compactMap { ($0["amount"] as? NSNumber)?.uint64Value }
            .reduce(0, +)
    }

    func waitForFrozenBalance(
        of address: String,
        resource: Resource,
        atLeast expected: UInt64,
        timeout: TimeInterval
    ) async throws -> UInt64 {
        let deadline = Date.now.addingTimeInterval(timeout)
        var latest = try await frozenBalance(of: address, resource: resource)

        while latest < expected, Date.now < deadline {
            try await Task.sleep(for: .seconds(2))
            latest = try await frozenBalance(of: address, resource: resource)
        }

        return latest
    }
}

private extension XCUIApplication {
    func firstDescendant(withIdentifier identifier: String) -> XCUIElement {
        descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@", identifier))
            .firstMatch
    }
}
