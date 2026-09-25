import BigInt
import Foundation
import XCTest
import WalletKitTesting

/// Expected values for one row of the account transactions table.
private struct ExpectedTransaction {
    let identifier: String
    let kinds: Set<String>
    let sender: String
    let recipient: String?
}

/// End-to-end transaction-history UI coverage against an ephemeral local anvil node.
@MainActor
final class AnvilTransactionHistoryUITests: XCTestCase {
    private let mnemonic = "test test test test test test test test test test test junk"
    private var app: XCUIApplication!
    private var anvilNode: AnvilNode!
    private var expectedTransactions: [ExpectedTransaction] = []

    override func setUp() async throws {
        continueAfterFailure = false

        anvilNode = try await AnvilNode.start()
        expectedTransactions = try await prepareEVMTransactions(node: anvilNode)

        app = XCUIApplication(bundleIdentifier: "xyz.reefr.wallet")
        app.launchArguments = [
            "--test",
            "--mnemonic",
            mnemonic,
            "--evm-rpc-url",
            anvilNode.endpoint.absoluteString,
            "--create-evm-accounts"
        ]
    }

    override func tearDown() {
        anvilNode?.stop()
        anvilNode = nil
        app = nil
    }

    func testAnvilAccountsShowCapturedTransactionHashes() {
        app.launch()
        app.activate()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        // Allow the app's descending history scan to observe both committed transfers.
        sleep(20)

        for accountNumber in 1 ... 2 {
            let accountLabel = app.firstDescendant(withIdentifier: "sidebar-account-label-Sepolia #\(accountNumber)")

            XCTAssertTrue(accountLabel.waitForExistence(timeout: 20))
            accountLabel.click()

            let transactionsTab = app
                .descendants(matching: .any)
                .matching(NSPredicate(format: "label == %@", "Transactions"))
                .firstMatch

            XCTAssertTrue(transactionsTab.waitForExistence(timeout: 10))
            transactionsTab.click()

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
        XCTAssertTrue(expected.kinds.contains(kindCell.value as? String ?? ""), "Unexpected kind for \(expected.identifier)")

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

    private func prepareEVMTransactions(node: AnvilNode) async throws -> [ExpectedTransaction] {
        let seed = try Mnemonic.fromPhrase(mnemonic).toSeed()

        let signers = try (0 ..< 2).map { index in
            let path = try DerivationPath(string: "m/44'/60'/0'/0/\(index)")
            let key = try seed.masterKey(curve: .secp256k1).derive(path).privateKey()

            return try EthereumPKeySigner(
                chainId: node.chainId,
                privateKey: key,
                derivationPath: path
            )
        }

        let addresses = try signers.map { try $0.address() }

        for address in addresses {
            try await node.setBalance(address, wei: 10_000_000_000_000_000_000)
        }

        let first = try await node.send(
            signer: signers[0],
            to: addresses[1],
            value: 1_000_000_000_000_000_000,
            gasLimit: 21_000
        )

        let second = try await node.send(
            signer: signers[1],
            to: addresses[0],
            value: 500_000_000_000_000_000,
            gasLimit: 21_000
        )

        return [
            ExpectedTransaction(
                identifier: first,
                kinds: ["received", "sent"],
                sender: addresses[0].string,
                recipient: addresses[1].string
            ),
            ExpectedTransaction(
                identifier: second,
                kinds: ["received", "sent"],
                sender: addresses[1].string,
                recipient: addresses[0].string
            )
        ]
    }
}

private extension XCUIApplication {
    func firstDescendant(withIdentifier identifier: String) -> XCUIElement {
        descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@", identifier))
            .firstMatch
    }
}
