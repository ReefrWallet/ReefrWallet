import BigInt
import Foundation
import XCTest
import WalletKit

/// End-to-end transaction-history UI coverage against ephemeral local nodes.
@MainActor
final class LocalNodeTransactionUITests: XCTestCase {
    private let mnemonic = "test test test test test test test test test test test junk"
    private var app: XCUIApplication!
    private var anvilNode: AnvilNode!
    private var suiNode: SuiNode!
    private var transactionIdentifiers: [String] = []
    private var isSuiTest = false

    override func setUp() async throws {
        continueAfterFailure = false
        isSuiTest = name.contains("Sui")

        anvilNode = try await AnvilNode.start()
        suiNode = try await SuiNode.start()

        let evmTransactionIdentifiers = try await prepareEVMTransactions(node: anvilNode)
        let suiTransactionIdentifiers = try await prepareSuiTransactions(node: suiNode)
        transactionIdentifiers = isSuiTest ? suiTransactionIdentifiers : evmTransactionIdentifiers

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

            for identifier in transactionIdentifiers {
                XCTAssertTrue(
                    app.descendants(matching: .any)["transaction-hash-\(identifier)"].waitForExistence(timeout: 10),
                    "Expected captured transaction identifier \(identifier)"
                )
            }

            sleep(10)
        }
    }

    private func prepareEVMTransactions(node: AnvilNode) async throws -> [String] {
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

        return [first, second]
    }

    private func prepareSuiTransactions(node: SuiNode) async throws -> [String] {
        let seed = try Mnemonic.fromPhrase(mnemonic).toSeed()

        let keys = try (0 ..< 2).map { index in
            let accountPath = try DerivationPath(string: "m/44'/784'/\(index)'/0'/0'")
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
    ) async throws -> String {
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

        return digest
    }

    private func accountName(number: Int) -> String {
        isSuiTest ? "Sui Testnet #\(number)" : "Ethereum Testnet #\(number)"
    }
}
