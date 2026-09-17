import BigInt
import Foundation
@testable import ReefrWallet
import SwiftData
import Testing
import WalletKit

@Suite(.timeLimit(.minutes(3)), .serialized)
struct TransactionSyncServiceTests {
    @Test
    func capturesTwoWayLocalEthereumAndSuiTransfers() async throws {
        let fixture = try await TransactionSyncFixture.make()

        defer {
            fixture.anvilNode.stop()
            fixture.suiNode.stop()
        }

        let expectedTransactions = try await fixture.broadcastTransactions()

        let service = TransactionSyncService(databaseService: fixture.databaseService)
        await service.startAll()

        try await fixture.waitForTransactions(expectedTransactions)

        for account in fixture.accounts {
            await service.stop(account)
        }
    }

    @Test
    func syncsWatchOnlyEthereumSepoliaTransactions() async throws {
        let addresses = [
            "0x69267E677d8C23414Ff802301fcA99442Aafe366",
            "0xB86CEB97f6E01eFC6D651fDdF00a8FDc850542F2"
        ]

        let databaseService = try makeDatabaseService()
        let keyStore = try await databaseService.watchOnlyKeyStore()

        guard let keyStoreID = keyStore.id else {
            throw Error.invalidData
        }

        var accounts = addresses.enumerated().map { index, address in
            Account(
                accountIndex: nil,
                address: address,
                blockchain: .evm(.ethereum(.testnet)),
                derivationPath: nil,
                keyStoreId: keyStoreID,
                name: "Ethereum Sepolia Watch-Only #\(index + 1)"
            )
        }

        for index in accounts.indices {
            accounts[index].id = try await databaseService.insertAccount(accounts[index], keyStore: keyStore)
        }

        let service = TransactionSyncService(databaseService: databaseService)
        await service.startAll()

        defer {
            Task {
                for account in accounts {
                    await service.stop(account)
                }
            }
        }

        let deadline = ContinuousClock.now.advanced(by: .seconds(150))

        while ContinuousClock.now < deadline {
            var transactionsWereSaved = true

            for account in accounts {
                guard let accountID = account.id else {
                    throw Error.invalidData
                }

                if try await databaseService.fetchTransactions(accountId: accountID).isEmpty {
                    transactionsWereSaved = false
                    break
                }
            }

            if transactionsWereSaved {
                return
            }

            try await Task.sleep(for: .milliseconds(500))
        }

        for account in accounts {
            guard let accountID = account.id else {
                throw Error.invalidData
            }

            let transactions = try await databaseService.fetchTransactions(accountId: accountID)
            let syncState = try await databaseService.transactionSyncState(accountId: accountID)

            #expect(
                !transactions.isEmpty,
                "No Ethereum Sepolia transactions were saved for \(account.address). Sync error: \(syncState.lastError ?? "none")"
            )
        }
    }

    @Test
    func resolvesBlockscoutSourcesForSupportedEVMNetworks() {
        let defaultSource = BlockscoutTransactionHistorySource()

        #expect(defaultSource.supports(.evm(.arbitrum(.mainnet))))
        #expect(defaultSource.supports(.evm(.arbitrum(.testnet))))
        #expect(!defaultSource.supports(.evm(.bsc(.mainnet))))
        #expect(defaultSource.supports(.evm(.ethereum(.mainnet))))
        #expect(defaultSource.supports(.evm(.ethereum(.testnet))))

        let customEndpoint = URL(string: "https://explorer.example.com/api/v2")!
        let customSource = BlockscoutTransactionHistorySource(apiBaseURLs: [
            56: customEndpoint,
            31337: customEndpoint
        ])

        #expect(customSource.supports(.evm(.bsc(.mainnet))))
        #expect(customSource.supports(.evm(.custom(31337))))
    }

    @Test
    func syncsWatchOnlySuiTestnetTransactions() async throws {
        let addresses = [
            "0x0394a0edf52d7164a995311b56031a7e8262dff33566edcbd7b1279d380cf0bd",
            "0x72e49ba9922e7641d6bd23c1f6fd6e30c195634485b8427c8fba8a98de6c03b0"
        ]

        let databaseService = try makeDatabaseService()
        let keyStore = try await databaseService.watchOnlyKeyStore()

        guard let keyStoreID = keyStore.id else {
            throw Error.invalidData
        }

        var accounts = addresses.enumerated().map { index, address in
            Account(
                accountIndex: nil,
                address: address,
                blockchain: .sui(.testnet),
                derivationPath: nil,
                keyStoreId: keyStoreID,
                name: "Sui Testnet Watch-Only #\(index + 1)"
            )
        }

        for index in accounts.indices {
            accounts[index].id = try await databaseService.insertAccount(accounts[index], keyStore: keyStore)
        }

        let service = TransactionSyncService(databaseService: databaseService)
        await service.startAll()

        defer {
            Task {
                for account in accounts {
                    await service.stop(account)
                }
            }
        }

        let deadline = ContinuousClock.now.advanced(by: .seconds(55))

        while ContinuousClock.now < deadline {
            var transactionsWereSaved = true

            for account in accounts {
                guard let accountID = account.id else {
                    throw Error.invalidData
                }

                if try await databaseService.fetchTransactions(accountId: accountID).isEmpty {
                    transactionsWereSaved = false
                    break
                }
            }

            if transactionsWereSaved {
                return
            }

            try await Task.sleep(for: .milliseconds(500))
        }

        for account in accounts {
            guard let accountID = account.id else {
                throw Error.invalidData
            }

            let transactions = try await databaseService.fetchTransactions(accountId: accountID)
            let syncState = try await databaseService.transactionSyncState(accountId: accountID)

            #expect(
                !transactions.isEmpty,
                "No Sui testnet transactions were saved for \(account.address). Sync error: \(syncState.lastError ?? "none")"
            )
        }
    }
}

private struct TransactionSyncFixture {
    let anvilNode: AnvilNode
    let suiNode: SuiNode
    let databaseService: DatabaseService
    let keyStore: KeyStore
    let ethereumAccounts: [Account]
    let suiAccounts: [Account]

    var accounts: [Account] {
        ethereumAccounts + suiAccounts
    }

    static func make() async throws -> TransactionSyncFixture {
        let anvilNode = try await startAnvilNode()
        let suiNode = try await SuiNode.start()

        let databaseService = try makeDatabaseService()

        let mnemonic = try Mnemonic.fromPhrase("test test test test test test test test test test test junk")
        let keyStore = try await databaseService.makeMockKeyStore(mnemonic: mnemonic)

        let ethereumAccounts = try await databaseService.makeMockEthereumAccounts(
            keyStore: keyStore,
            chainID: anvilNode.chainId,
            rpcURLOverride: anvilNode.endpoint
        )

        let suiAccounts = try await databaseService.makeMockSuiAccounts(
            keyStore: keyStore,
            rpcURLOverride: URL(string: "http://127.0.0.1:\(suiNode.rpcPort)")!
        )

        return TransactionSyncFixture(
            anvilNode: anvilNode,
            suiNode: suiNode,
            databaseService: databaseService,
            keyStore: keyStore,
            ethereumAccounts: ethereumAccounts,
            suiAccounts: suiAccounts
        )
    }

    func broadcastTransactions() async throws -> [PersistentIdentifier: Set<String>] {
        let ethereumTransactionHashes = try await broadcastEthereumTransactions()
        let suiTransactionDigests = try await broadcastSuiTransactions()
        let ethereumExpected = Set(ethereumTransactionHashes)
        let suiExpected = Set(suiTransactionDigests)

        return try [
            requiredID(ethereumAccounts[0]): ethereumExpected,
            requiredID(ethereumAccounts[1]): ethereumExpected,
            requiredID(suiAccounts[0]): suiExpected,
            requiredID(suiAccounts[1]): suiExpected
        ]
    }

    func waitForTransactions(_ expected: [PersistentIdentifier: Set<String>]) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))

        while ContinuousClock.now < deadline {
            var allTransactionsPresent = true

            for (accountID, identifiers) in expected {
                let transactions = try await databaseService.fetchTransactions(accountId: accountID)
                let savedIdentifiers = Set(transactions.map(\.stableID))

                if !identifiers.allSatisfy({ identifier in
                    savedIdentifiers.contains { $0.hasSuffix("|\(identifier)") }
                }) {
                    allTransactionsPresent = false
                    break
                }
            }

            if allTransactionsPresent {
                return
            }

            try await Task.sleep(for: .milliseconds(250))
        }

        var missing: [String] = []

        for (accountID, identifiers) in expected {
            let transactions = try await databaseService.fetchTransactions(accountId: accountID)
            let savedIdentifiers = Set(transactions.map(\.stableID))

            missing.append(contentsOf: identifiers.filter { identifier in
                !savedIdentifiers.contains { $0.hasSuffix("|\(identifier)") }
            })
        }

        throw TransactionSyncTestError.missingTransactions(missing)
    }

    private func broadcastEthereumTransactions() async throws -> [String] {
        let firstSigner = try ethereumSigner(at: 0)
        let secondSigner = try ethereumSigner(at: 1)
        let firstAddress = try firstSigner.address()
        let secondAddress = try secondSigner.address()
        let initialNativeBalance = BigUInt(10_000_000_000_000_000_000)

        try await anvilNode.setBalance(firstAddress, wei: initialNativeBalance)
        try await anvilNode.setBalance(secondAddress, wei: initialNativeBalance)

        let blockchain = WKBlockchain.evm(.custom(anvilNode.chainId))
        let deployer = try await makeFundedDeployer(node: anvilNode, blockchain: blockchain)
        let token = try await deployMockUSDC(deployer: deployer)
        try await mintMockUSDC(deployer: deployer, mockUSDCAddress: token, wallet: firstAddress, amount: 200_000_000)
        try await mintMockUSDC(deployer: deployer, mockUSDCAddress: token, wallet: secondAddress, amount: 200_000_000)

        let nativeOneToTwo = try await anvilNode.send(
            signer: firstSigner,
            to: secondAddress,
            value: 1_000_000_000_000_000,
            gasLimit: 21000
        )
        
        let tokenOneToTwo = try await anvilNode.send(
            signer: firstSigner,
            to: token,
            data: EthereumABI.encodeCall(
                selector: EthereumABI.selector("transfer(address,uint256)"),
                parameters: [.address(secondAddress), .uint256(50_000_000)]
            ),
            gasLimit: 100_000
        )

        let nativeTwoToOne = try await anvilNode.send(
            signer: secondSigner,
            to: firstAddress,
            value: 500_000_000_000_000,
            gasLimit: 21000
        )

        let tokenTwoToOne = try await anvilNode.send(
            signer: secondSigner,
            to: token,
            data: EthereumABI.encodeCall(
                selector: EthereumABI.selector("transfer(address,uint256)"),
                parameters: [.address(firstAddress), .uint256(25_000_000)]
            ),
            gasLimit: 100_000
        )

        return [nativeOneToTwo, tokenOneToTwo, nativeTwoToOne, tokenTwoToOne]
    }

    private func broadcastSuiTransactions() async throws -> [String] {
        let firstSigner = try suiSigner(at: 0)
        let secondSigner = try suiSigner(at: 1)
        let firstAddress = try firstSigner.address()
        let secondAddress = try secondSigner.address()
        let client = SuiGRPCClient(host: "127.0.0.1", port: Int(suiNode.rpcPort), useTLS: false)

        try await suiNode.faucet(firstAddress)
        try await suiNode.faucet(secondAddress)
        try await suiNode.waitForSuiCoinCount(of: firstAddress, atLeast: 1)
        try await suiNode.waitForSuiCoinCount(of: secondAddress, atLeast: 1)

        return try [
            await sendSui(client: client, signer: firstSigner, recipient: secondAddress),
            await sendSui(client: client, signer: secondSigner, recipient: firstAddress)
        ]
    }

    private func ethereumSigner(at index: UInt64) throws -> EthereumPKeySigner {
        let path = try DerivationPath(.evm(.custom(anvilNode.chainId)), accountIndex: index, curve: .secp256k1)
        let privateKey = try Seed(rawBytes: requiredRawKey()).masterKey(curve: .secp256k1).derive(path).privateKey()
        return try EthereumPKeySigner(chainId: anvilNode.chainId, privateKey: privateKey, derivationPath: path)
    }

    private func suiSigner(at index: UInt64) throws -> SuiPKeySigner {
        let path = try DerivationPath(.sui(.testnet), accountIndex: index, curve: .ed25519)
        let privateKey = try Seed(rawBytes: requiredRawKey()).masterKey(curve: .ed25519).derive(path).privateKey()
        return try SuiPKeySigner(curve: .ed25519, privateKey: privateKey, derivationPath: path)
    }

    private func sendSui(client: SuiGRPCClient, signer: SuiPKeySigner, recipient: SuiAddress) async throws -> String {
        let sender = try signer.address()

        let transaction = try UnsignedSuiTransaction(
            sender: sender,
            transfers: [(recipient: recipient, amount: 1_000_000_000)],
            gasPayment: [await suiNode.largestSuiCoin(of: sender)],
            gasOwner: sender,
            gasPrice: await suiNode.referenceGasPrice(),
            gasBudget: 10_000_000
        )

        let signature = try await signer.sign(transaction: transaction.transactionDataBcs)
        let digest = try await client.broadcast(transactionData: transaction.transactionDataBcs, signature: signature)

        _ = try await suiNode.waitForEffects(digest)

        return digest
    }

    private func requiredRawKey() throws -> Data {
        guard let rawKey = keyStore.rawKey else {
            throw Error.invalidData
        }

        return rawKey
    }

    private func requiredID(_ account: Account) throws -> PersistentIdentifier {
        guard let id = account.id else {
            throw Error.invalidData
        }

        return id
    }
}

private enum TransactionSyncTestError: LocalizedError {
    case missingTransactions([String])

    var errorDescription: String? {
        switch self {
        case let .missingTransactions(identifiers):
            "Timed out waiting for synced transactions: \(identifiers.joined(separator: ", "))"
        }
    }
}
