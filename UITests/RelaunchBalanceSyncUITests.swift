import BigInt
import Foundation
import XCTest
import WalletKitTesting

/// UI regression coverage for "balances don't update after the initial
/// save", on every chain with a local node (Bitcoin excluded):
///
/// 1. Launch with a fixed mnemonic; the recipient's initial balances show.
/// 2. Quit; the sender transfers to the recipient outside the app.
/// 3. Relaunch onto the same store: balances and the incoming transaction
///    appear with no user action.
/// 4. Quit; transfer again; relaunch with sync disabled: the sidebar's Update
///    button alone brings the balances up to date.
@MainActor
final class RelaunchBalanceSyncUITests: XCTestCase {
    private let mnemonic = "test test test test test test test test test test test junk"
    private var app: XCUIApplication!
    private var stopNode: (() -> Void)?
    private var storeDirectory: URL!

    override func setUp() async throws {
        // Stage checks throw `UITestFailure` to end a test; `continueAfterFailure = false`
        // aborts async tests from inside XCTest and hangs the async tear-down.
        continueAfterFailure = true

        storeDirectory = FileManager.default.temporaryDirectory.appending(path: "relaunch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        app = XCUIApplication(bundleIdentifier: "xyz.reefr.wallet")
    }

    override func tearDown() {
        app?.terminate()
        stopNode?()
        try? FileManager.default.removeItem(at: storeDirectory)
        app = nil
        stopNode = nil
    }

    func testEVMBalancesAndTransactionsCatchUpAfterRelaunch() async throws {
        let node = try await EthereumNode.start()
        stopNode = node.stop

        let signers = try (0 ..< 2).map { index in
            try EthereumPKeySigner(
                chainId: node.chainId,
                privateKey: privateKey(path: "m/44'/60'/0'/0/\(index)", curve: .secp256k1),
                derivationPath: DerivationPath(string: "m/44'/60'/0'/0/\(index)")
            )
        }

        let addresses = try signers.map { try $0.address() }
        try await node.setBalance(addresses[0], wei: 10_000_000_000_000_000_000)
        try await node.setBalance(addresses[1], wei: 1_000_000_000_000_000_000)

        let usdc = try await node.deployMockERC20(signer: signers[0])
        _ = try await node.faucetERC20(signer: signers[0], token: usdc, recipient: addresses[0], amount: 1_000_000_000)
        _ = try await node.faucetERC20(signer: signers[0], token: usdc, recipient: addresses[1], amount: 3_060_000)

        let client = EthereumRPCClient(endpoint: node.endpoint, chainId: node.chainId)

        try await runScenario(ChainUnderTest(
            launchArguments: ["--evm-rpc-url", node.endpoint.absoluteString, "--create-evm-accounts"],
            recipientName: "Sepolia #2",
            assets: [
                Asset(symbol: "ETH", decimals: 18) { try await client.nativeBalance(of: addresses[1]) },
                Asset(symbol: "USDC", decimals: 6) { try await client.erc20Balance(token: usdc, owner: addresses[1]) }
            ]
        ) { reserve in
            let native = try await node.send(
                signer: signers[0],
                to: addresses[1],
                value: 250_000_000_000_000_000,
                gasLimit: 21_000
            )

            let token = try await node.transferERC20(
                signer: signers[0],
                token: usdc,
                recipient: addresses[1],
                amount: try randomTokenAmount(
                    available: try await client.erc20Balance(token: usdc, owner: addresses[0]),
                    reserve: reserve
                )
            )

            // Anvil mines on demand only: leave a gap wider than one forward-scan page.
            try await node.mine(blocks: 25)
            return [native, token]
        })
    }

    func testSolanaBalancesAndTransactionsCatchUpAfterRelaunch() async throws {
        let node = try await SolanaNode.start()
        stopNode = node.stop

        let signers = try (0 ..< 2).map { index in
            try SolanaPKeySigner(
                network: .devnet,
                privateKey: privateKey(path: "m/44'/501'/\(index)'/0'", curve: .ed25519),
                derivationPath: DerivationPath(string: "m/44'/501'/\(index)'/0'")
            )
        }

        let addresses = try signers.map { try $0.address() }

        for address in addresses {
            _ = try await node.airdrop(to: address, lamports: 2_000_000_000)
        }

        let client = SolanaRPCClient(endpoint: node.rpcURL)
        let builder = SolanaTransactionBuilder(client: client)
        let mint = try await node.mintSPLToken(decimals: 6, to: addresses[0], amount: 1_000_000_000)

        let transfer: (String?, BigUInt) async throws -> String = { token, amount in
            let unsigned = try await builder.buildTransfer(
                sender: addresses[0],
                recipient: addresses[1],
                amount: amount,
                token: token,
                options: []
            )

            let signature = try await client.broadcast(
                transaction: unsigned,
                signature: try await signers[0].sign(transaction: unsigned)
            )

            try await node.waitForConfirmation(signature: signature)
            return signature
        }

        // The recipient starts with a small token balance, like the report.
        _ = try await transfer(mint.string, 3_060_000)

        // Mints without Metaplex metadata are shown by their abbreviated address.
        let mintSymbol = "\(mint.string.prefix(4))…\(mint.string.suffix(4))"

        try await runScenario(ChainUnderTest(
            launchArguments: ["--solana-rpc-url", node.rpcURL.absoluteString, "--create-solana-accounts"],
            recipientName: "Devnet #2",
            assets: [
                Asset(symbol: "SOL", decimals: 9) { try await client.getNativeBalance(addresses[1]) },
                Asset(symbol: mintSymbol, decimals: 6) { try await client.getBalance(addresses[1], token: mint.string) }
            ]
        ) { reserve in
            let tokenAmount = try randomTokenAmount(
                available: try await client.getBalance(addresses[0], token: mint.string),
                reserve: reserve
            )

            return [try await transfer(nil, 250_000_000), try await transfer(mint.string, tokenAmount)]
        })
    }

    func testSuiBalancesAndTransactionsCatchUpAfterRelaunch() async throws {
        let node = try await SuiNode.start()
        stopNode = node.stop

        let signers = try (0 ..< 2).map { index in
            try SuiPKeySigner(
                curve: .ed25519,
                privateKey: privateKey(path: "m/44'/784'/0'/0'/\(index)'", curve: .ed25519),
                derivationPath: DerivationPath(string: "m/44'/784'/0'/0'/\(index)'")
            )
        }

        let addresses = try signers.map { try $0.address() }

        for address in addresses {
            try await node.faucet(address)
            try await node.waitForSuiCoinCount(of: address, atLeast: 1)
        }

        let client = SuiGRPCClient(host: "127.0.0.1", port: Int(node.rpcPort), useTLS: false)
        let builder = SuiTransactionBuilder(client: client)

        // Sui custom coins need a published Move package: native SUI only.
        try await runScenario(ChainUnderTest(
            launchArguments: ["--sui-rpc-url", "http://127.0.0.1:\(node.rpcPort)", "--create-sui-accounts"],
            recipientName: "Testnet #2",
            assets: [Asset(symbol: "SUI", decimals: 9) { try await client.getNativeBalance(addresses[1]) }]
        ) { _ in
            let unsigned = try await builder.buildTransfer(
                sender: addresses[0],
                recipient: addresses[1],
                amount: 250_000_000,
                token: nil
            )

            let digest = try await client.broadcast(
                transactionData: unsigned,
                signature: try await signers[0].sign(transaction: unsigned)
            )

            _ = try await node.waitForEffects(digest)
            return [digest]
        })
    }

    /// Public-testnet version of the reported case: real Sepolia USDC between
    /// the mnemonic's first two accounts, over the default endpoints and
    /// indexer (no RPC override). Runs only when `REEFR_TESTNET_MNEMONIC` is set
    /// (forwarded by `Project.swift`), since it spends gas. Both accounts need
    /// Sepolia ETH; whatever USDC is sent is sent back.
    func testSepoliaUSDCTransferCatchesUpAfterRelaunch() async throws { // swiftlint:disable:this function_body_length
        let environment = ProcessInfo.processInfo.environment
        let testnetMnemonic = environment["REEFR_TESTNET_MNEMONIC"] ?? ""
        try XCTSkipIf(testnetMnemonic.isEmpty, "Set REEFR_TESTNET_MNEMONIC to run against Sepolia.")
        let chainId: UInt64 = 11_155_111
        let usdc = try EthereumAddress(string: "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238")
        let client = EthereumRPCClient(
            endpoint: try XCTUnwrap(URL(string: "https://ethereum-sepolia-rpc.publicnode.com")),
            chainId: chainId
        )

        let signers = try (0 ..< 2).map { index in
            let path = "m/44'/60'/0'/0/\(index)"
            return try EthereumPKeySigner(
                chainId: chainId,
                privateKey: Mnemonic.fromPhrase(testnetMnemonic)
                    .toSeed()
                    .masterKey(curve: .secp256k1)
                    .derive(DerivationPath(string: path))
                    .privateKey(),
                derivationPath: DerivationPath(string: path)
            )
        }

        let addresses = try signers.map { try $0.address() }

        for address in addresses {
            let gas = try await client.nativeBalance(of: address)
            try require(gas >= 200_000_000_000_000, "\(address.string) needs Sepolia ETH for gas (has \(gas) wei).")
        }

        // A random amount up to the sender's whole balance; the same amount is sent back.
        let amount = try randomTokenAmount(available: try await client.erc20Balance(token: usdc, owner: addresses[0]))

        let send: (Int, Int) async throws -> String = { from, to in
            try await sendSepoliaUSDC(
                client: client,
                signer: signers[from],
                recipient: addresses[to],
                token: usdc,
                amount: amount
            )
        }

        var owesTransferBack = false

        let chain = ChainUnderTest(
            launchArguments: ["--create-evm-accounts"],
            recipientName: "Sepolia #2",
            assets: [
                Asset(symbol: "ETH", decimals: 18) { try await client.nativeBalance(of: addresses[1]) },
                Asset(symbol: "USDC", decimals: 6) { try await client.erc20Balance(token: usdc, owner: addresses[1]) }
            ]
        ) { _ in
            [try await send(0, 1)]
        }

        // Public endpoints and the indexer lag behind the chain: allow one minute
        // for a transfer to be mined and indexed (local nodes get 30 seconds).
        let syncTimeout: TimeInterval = 60

        // 1. First launch: initial balances.
        try launch(["--mnemonic", testnetMnemonic] + chain.launchArguments)
        try openAccount(chain.recipientName, tab: "Token Balances")
        try await expectBalancesMatchChain(chain, stage: "Sepolia initial launch", timeout: syncTimeout)
        app.terminate()

        do {
            // 2. Closed: USDC arrives. 3. Relaunch: balance and transaction catch up.
            let identifiers = try await chain.transfer(0)
            owesTransferBack = true

            try launch([])
            try openAccount(chain.recipientName, tab: "Token Balances")
            try await expectBalancesMatchChain(chain, stage: "Sepolia relaunch", timeout: syncTimeout)
            try expectTransactions(identifiers, stage: "Sepolia relaunch")
            app.terminate()

            // 4. Closed: send the USDC back. The Update button alone must catch up.
            _ = try await send(1, 0)
            owesTransferBack = false

            try launch(["--disable-transaction-sync"])
            try openAccount(chain.recipientName, tab: "Token Balances")
            try clickUpdate()
            try await expectBalancesMatchChain(chain, stage: "Sepolia Update button", timeout: 30)
        } catch {
            if owesTransferBack {
                _ = try? await send(1, 0)
            }

            throw error
        }
    }
}

// MARK: - Sepolia

/// Sends `amount` of the ERC-20 `token` and waits (up to a minute — Sepolia
/// blocks are 12 seconds apart) for a successful receipt.
private func sendSepoliaUSDC(
    client: EthereumRPCClient,
    signer: EthereumPKeySigner,
    recipient: EthereumAddress,
    token: EthereumAddress,
    amount: BigUInt
) async throws -> String {
    let unsigned = try await EthereumTransactionBuilder(client: client).buildTransfer(
        sender: try signer.address(),
        recipient: recipient,
        amount: amount,
        token: token.string,
        options: []
    )

    let hash = try await client.broadcast(try await signer.sign(transaction: unsigned))
    let params = try JSONSerialization.data(withJSONObject: [hash])
    let deadline = Date.now.addingTimeInterval(60)

    while Date.now < deadline {
        let raw = try await client.request(method: "eth_getTransactionReceipt", params: params)

        if let receipt = try JSONSerialization.jsonObject(with: raw, options: .fragmentsAllowed) as? [String: Any] {
            guard receipt["status"] as? String == "0x1" else {
                throw UITestFailure(description: "Sepolia transaction \(hash) reverted.")
            }

            return hash
        }

        try await Task.sleep(for: .seconds(3))
    }

    throw UITestFailure(description: "Sepolia transaction \(hash) wasn't mined within 60 seconds.")
}

// MARK: - Scenario

private struct Asset {
    let symbol: String
    let decimals: Int
    /// The recipient's balance, read from the node.
    let chainBalance: () async throws -> BigUInt
}

private struct ChainUnderTest {
    let launchArguments: [String]
    let recipientName: String
    let assets: [Asset]
    /// Transfers every asset from the sender to the recipient and returns the
    /// transaction identifiers. Token amounts are random (see `randomTokenAmount`),
    /// keeping the given number of base units back for a later transfer.
    let transfer: (_ reserve: BigUInt) async throws -> [String]
}

/// A uniformly random token amount, in base units, in `1...(available - reserve)`.
/// Random amounts keep each transfer's balance change distinct from earlier ones.
private func randomTokenAmount(available: BigUInt, reserve: BigUInt = 0) throws -> BigUInt {
    let maximum = available > reserve ? available - reserve : 0

    guard maximum >= 1 else {
        throw UITestFailure(description: "Not enough to transfer: \(available) available, \(reserve) reserved.")
    }

    return BigUInt.randomInteger(lessThan: maximum) + 1
}

/// Ends a test with a readable message. Thrown rather than asserted: see `setUp`.
private struct UITestFailure: Error, CustomStringConvertible {
    let description: String
}

/// Timeouts for local nodes: UI elements and single small RPC round trips get
/// 10 seconds; a transfer being picked up by sync gets 30.
private enum Timeout {
    static let element: TimeInterval = 10
    static let refresh: TimeInterval = 10
    static let sync: TimeInterval = 30
}

private extension RelaunchBalanceSyncUITests {
    func runScenario(_ chain: ChainUnderTest) async throws {
        try launch(["--mnemonic", mnemonic] + chain.launchArguments)
        try openAccount(chain.recipientName, tab: "Token Balances")
        try await expectBalancesMatchChain(chain, stage: "initial launch", timeout: Timeout.sync)
        app.terminate()

        // Keep one unit back so the second round still has something to send.
        let identifiers = try await chain.transfer(1)

        try launch([])
        try openAccount(chain.recipientName, tab: "Token Balances")
        try await expectBalancesMatchChain(chain, stage: "relaunch", timeout: Timeout.sync)
        try expectTransactions(identifiers, stage: "relaunch")
        app.terminate()

        _ = try await chain.transfer(0)

        try launch(["--disable-transaction-sync"])
        try openAccount(chain.recipientName, tab: "Token Balances")
        try clickUpdate()
        try await expectBalancesMatchChain(chain, stage: "Update button", timeout: Timeout.refresh)
    }

    func require(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        guard condition else {
            throw UITestFailure(description: message())
        }
    }

    func launch(_ arguments: [String]) throws {
        app.launchArguments = ["--test", "--store-path", storeDirectory.appending(path: "keystore.sqlite").path]
            + arguments
        app.launch()
        app.activate()
        try require(app.windows.firstMatch.waitForExistence(timeout: Timeout.element), "The app window never appeared.")
    }

    func openAccount(_ name: String, tab: String) throws {
        let account = app.firstDescendant(withIdentifier: "sidebar-account-label-\(name)")
        try require(account.waitForExistence(timeout: Timeout.element), "Expected account \(name) in the sidebar.")
        account.click()
        try selectTab(tab)
    }

    func selectTab(_ label: String) throws {
        let tab = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", label))
            .firstMatch

        try require(tab.waitForExistence(timeout: Timeout.element), "Expected a \(label) tab.")
        tab.click()
    }

    func clickUpdate() throws {
        let updateButton = app.firstDescendant(withIdentifier: "sidebar-update-button")
        try require(updateButton.waitForExistence(timeout: Timeout.element), "Expected the sidebar Update button.")
        updateButton.click()
    }

    /// Checks the Transactions tab lists every identifier. Called once balances
    /// already match, so the rows only need to render.
    func expectTransactions(_ identifiers: [String], stage: String) throws {
        try selectTab("Transactions")

        for identifier in identifiers {
            try require(
                app.firstDescendant(withIdentifier: "transaction-hash-\(identifier)")
                    .waitForExistence(timeout: Timeout.element),
                "\(stage): the incoming transaction \(identifier) never appeared."
            )
        }
    }

    /// Polls until each asset's balance cell shows the node's current balance.
    ///
    /// Tokens without a USD price (every local mock) are listed under the
    /// collapsed Hidden Balances section, which is expanded whenever a row is
    /// missing — the section only appears once such a token is discovered.
    func expectBalancesMatchChain(_ chain: ChainUnderTest, stage: String, timeout: TimeInterval) async throws {
        let deadline = Date.now.addingTimeInterval(timeout)

        for asset in chain.assets {
            let cell = app.firstDescendant(withIdentifier: "balance-amount-\(asset.symbol)")
            var expected = ""
            var shown = "(no \(asset.symbol) row)"

            repeat {
                expected = formatted(try await asset.chainBalance(), decimals: asset.decimals)

                if cell.exists {
                    shown = cell.text

                    if shown == expected {
                        break
                    }
                } else {
                    expandHiddenBalancesIfCollapsed()
                }

                try await Task.sleep(for: .milliseconds(500))
            } while Date.now < deadline

            try require(
                shown == expected,
                "\(stage): \(chain.recipientName) \(asset.symbol) shows \(shown), the chain has \(expected)."
            )
        }
    }

    func expandHiddenBalancesIfCollapsed() {
        let triangle = app.outlines
            .matching(NSPredicate(format: "identifier == %@", "account-balances-content"))
            .firstMatch
            .descendants(matching: .disclosureTriangle)
            .firstMatch

        if triangle.exists, !triangle.isExpanded {
            triangle.click()
        }
    }

    /// Mirrors `BalancesTableEntry.displayAmount`.
    func formatted(_ amount: BigUInt, decimals: Int) -> String {
        let significand = Decimal(string: amount.description) ?? 0
        return Decimal(sign: .plus, exponent: -decimals, significand: significand).formatted(.number)
    }

    func privateKey(path: String, curve: Curve) throws -> PrivateKey {
        try Mnemonic.fromPhrase(mnemonic)
            .toSeed()
            .masterKey(curve: curve)
            .derive(DerivationPath(string: path))
            .privateKey()
    }
}

private extension XCUIApplication {
    func firstDescendant(withIdentifier identifier: String) -> XCUIElement {
        descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@", identifier))
            .firstMatch
    }
} // swiftlint:disable:this file_length
