import BigInt
import Foundation
import XCTest
import WalletKitTesting

/// Expected values for one row of the account transactions table.
///
/// `recipient` is `nil` when the chain doesn't populate a top-level "To" —
/// Sui balance changes can touch several addresses, so only the per-effect
/// `to` carries that information, and the table's "To" column stays blank.
private struct ExpectedTransaction {
    let identifier: String
    let method: String
    let sender: String
    let recipient: String?
}

/// End-to-end transaction-history UI coverage against ephemeral local nodes.
@MainActor
final class LocalNodeTransactionUITests: XCTestCase {
    private let mnemonic = "test test test test test test test test test test test junk"
    private var app: XCUIApplication!
    private var anvilNode: AnvilNode!
    private var suiNode: SuiNode!
    private var expectedTransactions: [ExpectedTransaction] = []
    private var isSuiTest = false

    override func setUp() async throws {
        continueAfterFailure = false
        isSuiTest = name.contains("Sui")

        anvilNode = try await AnvilNode.start()
        suiNode = try await SuiNode.start()

        let evmTransactions = try await prepareEVMTransactions(node: anvilNode)
        let suiTransactions = try await prepareSuiTransactions(node: suiNode)
        expectedTransactions = isSuiTest ? suiTransactions : evmTransactions

        app = XCUIApplication(bundleIdentifier: "xyz.reefr.wallet")
        app.launchArguments = [
            "--test",
            "--mnemonic",
            mnemonic,
            "--sui-rpc-url",
            "http://127.0.0.1:\(suiNode.rpcPort)",
            "--evm-rpc-url",
            anvilNode.endpoint.absoluteString
        ]
    }

    override func tearDown() {
        anvilNode?.stop()
        suiNode?.stop()
        anvilNode = nil
        suiNode = nil
        app = nil
    }

    func testAnvilAccountsShowCapturedTransactionHashes() {
        launchAndAssertTransactions()
    }

    func testSuiTestnetAccountsShowCapturedTransactionDigests() {
        launchAndAssertTransactions()
    }

    private func launchAndAssertTransactions() {
        app.launch()
        app.activate()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        // Allow the app's descending history scan to observe both committed transfers.
        sleep(20)

        for accountNumber in 1 ... 2 {
            let accountLabel = app.staticTexts[accountName(number: accountNumber)]

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
            XCTAssertEqual(transactionCount.label, "2 Transactions")

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

        let methodCell = app.descendants(matching: .any)["transaction-method-\(expected.identifier)"]
        XCTAssertTrue(methodCell.waitForExistence(timeout: timeout))
        XCTAssertEqual(methodCell.label, expected.method, "Unexpected method for \(expected.identifier)")

        let blockCell = app.descendants(matching: .any)["transaction-block-\(expected.identifier)"]
        XCTAssertTrue(blockCell.waitForExistence(timeout: timeout))
        XCTAssertNotNil(
            UInt64(blockCell.label),
            "Expected a numeric block height for \(expected.identifier), got '\(blockCell.label)'"
        )

        let fromCell = app.descendants(matching: .any)["transaction-from-\(expected.identifier)"]
        XCTAssertTrue(fromCell.waitForExistence(timeout: timeout))
        XCTAssertEqual(
            fromCell.label.lowercased(), expected.sender.lowercased(),
            "Unexpected sender for \(expected.identifier)"
        )

        let toCell = app.descendants(matching: .any)["transaction-to-\(expected.identifier)"]
        XCTAssertTrue(toCell.waitForExistence(timeout: timeout))

        guard let recipient = expected.recipient else {
            XCTAssertTrue(toCell.label.isEmpty, "Expected no recipient for \(expected.identifier)")
            return
        }

        XCTAssertEqual(
            toCell.label.lowercased(), recipient.lowercased(),
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
                method: "nativeTransfer",
                sender: addresses[0].string,
                recipient: addresses[1].string
            ),
            ExpectedTransaction(
                identifier: second,
                method: "nativeTransfer",
                sender: addresses[1].string,
                recipient: addresses[0].string
            )
        ]
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

        // Sui doesn't set a single top-level recipient: a transaction can move
        // balances to several addresses, so only the effect carries `to`.
        return ExpectedTransaction(
            identifier: digest,
            method: "balanceChange",
            sender: sender.string,
            recipient: nil
        )
    }

    private func accountName(number: Int) -> String {
        isSuiTest ? "Testnet #\(number)" : "Sepolia #\(number)"
    }
}
