import Foundation
import XCTest
import WalletKitTesting

/// Expected values for one row of the account transactions table.
///
/// `recipient` is `nil` because Sui doesn't set a single top-level "To" —
/// a transaction's balance changes can touch several addresses, so only the
/// per-effect `to` carries that information, and the table's "To" column
/// stays blank.
private struct ExpectedTransaction {
    let identifier: String
    let kinds: Set<String>
    let sender: String
    let recipient: String?
}

/// End-to-end transaction-history UI coverage against an ephemeral local Sui node.
@MainActor
final class SuiTransactionHistoryUITests: XCTestCase {
    private let mnemonic = "test test test test test test test test test test test junk"
    private var app: XCUIApplication!
    private var suiNode: SuiNode!
    private var expectedTransactions: [ExpectedTransaction] = []

    override func setUp() async throws {
        continueAfterFailure = false

        suiNode = try await SuiNode.start()
        expectedTransactions = try await prepareSuiTransactions(node: suiNode)

        app = XCUIApplication(bundleIdentifier: "xyz.reefr.wallet")
        app.launchArguments = [
            "--test",
            "--mnemonic",
            mnemonic,
            "--sui-rpc-url",
            "http://127.0.0.1:\(suiNode.rpcPort)",
            "--create-sui-accounts"
        ]
    }

    override func tearDown() {
        suiNode?.stop()
        suiNode = nil
        app = nil
    }

    func testSuiTestnetAccountsShowCapturedTransactionDigests() {
        app.launch()
        app.activate()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        // Allow the app's descending history scan to observe both committed transfers.
        sleep(20)

        for accountNumber in 1 ... 2 {
            let accountLabel = app.firstDescendant(withIdentifier: "sidebar-account-label-Testnet #\(accountNumber)")

            XCTAssertTrue(accountLabel.waitForExistence(timeout: 20))
            accountLabel.click()

            let transactionsTab = app
                .descendants(matching: .any)
                .matching(NSPredicate(format: "label == %@", "Transactions"))
                .firstMatch

            XCTAssertTrue(transactionsTab.waitForExistence(timeout: 10))
            transactionsTab.click()

            // Sui's faucet top-up in `setUp` is history of its own, so the
            // account can carry more than the two transfers captured here.
            let transactionCount = app.staticTexts["account-transactions-count"]
            XCTAssertTrue(transactionCount.waitForExistence(timeout: 10))

            let count = transactionCount.text.split(separator: " ").compactMap { Int($0) }.first ?? 0
            XCTAssertGreaterThanOrEqual(
                count, expectedTransactions.count,
                "Expected the captured transfers to be listed, got: \(transactionCount.text)"
            )

            for expected in expectedTransactions {
                assertRow(matches: expected, timeout: 10)
            }

            sleep(10)
        }
    }

    private func assertRow(matches expected: ExpectedTransaction, timeout: TimeInterval) {
        let hashCell = app.descendants(matching: .any)["transaction-hash-\(expected.identifier)"]

        XCTAssertTrue(
            hashCell.waitForExistence(timeout: timeout),
            "Expected captured transaction identifier \(expected.identifier)"
        )

        let kindCell = app.descendants(matching: .any)["transaction-kind-\(expected.identifier)"]
        XCTAssertTrue(kindCell.waitForExistence(timeout: timeout))
        let actualKind = kindCell.value as? String ?? "<none>"
        XCTAssertTrue(expected.kinds.contains(actualKind), "Unexpected kind '\(actualKind)' for \(expected.identifier)")

        let blockCell = app.descendants(matching: .any)["transaction-block-\(expected.identifier)"]
        XCTAssertTrue(blockCell.waitForExistence(timeout: timeout))
        XCTAssertNotNil(
            UInt64(blockCell.text),
            "Expected a numeric block height for \(expected.identifier), got '\(blockCell.text)'"
        )

        let fromCell = app.descendants(matching: .any)["transaction-from-\(expected.identifier)"]
        XCTAssertTrue(fromCell.waitForExistence(timeout: timeout))
        XCTAssertEqual(
            fromCell.text.lowercased(), expected.sender.lowercased(),
            "Unexpected sender for \(expected.identifier)"
        )

        let toCell = app.descendants(matching: .any)["transaction-to-\(expected.identifier)"]

        // A blank "To" draws no text, so the cell publishes no element at all.
        guard let recipient = expected.recipient else {
            XCTAssertFalse(toCell.exists, "Expected no recipient for \(expected.identifier)")
            return
        }

        XCTAssertTrue(toCell.waitForExistence(timeout: timeout))
        XCTAssertEqual(
            toCell.text.lowercased(), recipient.lowercased(),
            "Unexpected recipient for \(expected.identifier)"
        )
    }

    private func prepareSuiTransactions(node: SuiNode) async throws -> [ExpectedTransaction] {
        let seed = try Mnemonic.fromPhrase(mnemonic).toSeed()

        let keys = try (0 ..< 2).map { index in
            let accountPath = try DerivationPath(string: "m/44'/784'/0'/0'/\(index)'")
            let key = try seed.masterKey(curve: .ed25519).derive(accountPath).privateKey()

            return try SuiPKeySigner(
                curve: .ed25519,
                privateKey: key,
                derivationPath: accountPath
            )
        }

        let addresses = try keys.map { try $0.address() }
        let client = SuiGRPCClient(host: "127.0.0.1", port: Int(node.rpcPort), useTLS: false)

        for address in addresses {
            try await node.faucet(address)
        }

        try await node.waitForSuiCoinCount(of: addresses[0], atLeast: 1)
        try await node.waitForSuiCoinCount(of: addresses[1], atLeast: 1)

        let first = try await sendSUI(client: client, node: node, signer: keys[0], recipient: addresses[1])
        let second = try await sendSUI(client: client, node: node, signer: keys[1], recipient: addresses[0])

        return [first, second]
    }

    private func sendSUI(
        client: SuiGRPCClient,
        node: SuiNode,
        signer: SuiPKeySigner,
        recipient: SuiAddress
    ) async throws -> ExpectedTransaction {
        let sender = try signer.address()

        let transaction = UnsignedSuiTransaction(
            sender: sender,
            transfers: [(recipient: recipient, amount: 1_000_000_000)],
            gasPayment: [try await node.largestSuiCoin(of: sender)],
            gasOwner: sender,
            gasPrice: try await node.referenceGasPrice(),
            gasBudget: 10_000_000
        )

        let bcs = transaction.transactionDataBcs
        let signature = try await signer.sign(transaction: bcs)

        let digest = try await client.broadcast(transactionData: bcs, signature: signature)
        _ = try await node.waitForEffects(digest)

        return ExpectedTransaction(
            identifier: digest,
            kinds: ["received", "sent"],
            sender: sender.string,
            recipient: nil
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
