import BigInt
import Foundation
@testable import ReefrWallet
import SwiftData
import Testing
import WalletKitTesting

// swiftlint:disable type_body_length
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
    func capturesTransactionsBroadcastWhileSynchronizationContinues() async throws {
        let fixture = try await TransactionSyncFixture.make()

        defer {
            fixture.anvilNode.stop()
            fixture.suiNode.stop()
        }

        let initialHashes = Set(try await fixture.broadcastEthereumTransactions())

        let service = TransactionSyncService(
            databaseService: fixture.databaseService,
            transactionHistorySources: []
        )
        for account in fixture.ethereumAccounts {
            await service.start(account)
        }

        defer {
            Task {
                for account in fixture.ethereumAccounts {
                    await service.stop(account)
                }
            }
        }

        try await Task.sleep(for: .seconds(10))
        try await fixture.waitForEthereumTransactions(initialHashes, timeout: .milliseconds(250))

        let secondHash = try await fixture.sendNativeEthereumTransfer(from: 1, to: 0, value: 500_000_000_000_000)

        try await fixture.waitForEthereumTransactions(initialHashes.union([secondHash]), timeout: .seconds(10))
    }

    @Test
    func capturesSuiTransactionsBroadcastWhileSynchronizationContinues() async throws {
        let fixture = try await TransactionSyncFixture.make()

        defer {
            fixture.anvilNode.stop()
            fixture.suiNode.stop()
        }

        let initialDigests = Set(try await fixture.broadcastSuiTransactions())

        let service = TransactionSyncService(
            databaseService: fixture.databaseService,
            transactionHistorySources: []
        )

        for account in fixture.suiAccounts {
            await service.start(account)
        }

        defer {
            Task {
                for account in fixture.suiAccounts {
                    await service.stop(account)
                }
            }
        }

        try await Task.sleep(for: .seconds(10))
        try await fixture.waitForSuiTransactions(initialDigests, timeout: .milliseconds(250))

        let secondDigest = try await fixture.sendSuiTransfer(from: 1, to: 0)

        try await fixture.waitForSuiTransactions(initialDigests.union([secondDigest]), timeout: .seconds(10))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ETHERSCAN_API_KEY"] != nil))
    // swiftlint:disable:next function_body_length
    func syncsWatchOnlyEthereumSepoliaTransactions() async throws {
        let addresses = [
            "0x69267E677d8C23414Ff802301fcA99442Aafe366",
            "0xB86CEB97f6E01eFC6D651fDdF00a8FDc850542F2"
        ]

        guard let apiKey = ProcessInfo.processInfo.environment["ETHERSCAN_API_KEY"] else {
            throw Error.invalidData
        }

        let previousAPIKey = UserDefaults.standard.string(forKey: EtherscanTransactionHistorySource.apiKeyDefaultsKey)
        UserDefaults.standard.set(apiKey, forKey: EtherscanTransactionHistorySource.apiKeyDefaultsKey)

        defer {
            UserDefaults.standard.set(previousAPIKey, forKey: EtherscanTransactionHistorySource.apiKeyDefaultsKey)
        }

        let databaseService = try makeDatabaseService()
        let keyStore = try await databaseService.watchOnlyKeyStore()

        guard let keyStoreID = keyStore.id else {
            throw Error.invalidData
        }

        var accounts = addresses.enumerated().map { index, address in
            Account(
                accountIndex: nil,
                address: address,
                blockchain: .evm(.ethereum(.sepolia)),
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

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ETHERSCAN_API_KEY"] != nil
        || UserDefaults.standard.string(forKey: EtherscanTransactionHistorySource.apiKeyDefaultsKey) != nil))
    // swiftlint:disable:next function_body_length
    func syncsEthereumMainnetTokenBalancesAfterBackfill() async throws {
        guard let apiKey = ProcessInfo.processInfo.environment["ETHERSCAN_API_KEY"]
            ?? UserDefaults.standard.string(forKey: EtherscanTransactionHistorySource.apiKeyDefaultsKey) else {
            throw Error.invalidData
        }

        let previousAPIKey = UserDefaults.standard.string(forKey: EtherscanTransactionHistorySource.apiKeyDefaultsKey)
        UserDefaults.standard.set(apiKey, forKey: EtherscanTransactionHistorySource.apiKeyDefaultsKey)

        defer {
            UserDefaults.standard.set(previousAPIKey, forKey: EtherscanTransactionHistorySource.apiKeyDefaultsKey)
        }

        let databaseService = try makeDatabaseService()
        let keyStore = try await databaseService.watchOnlyKeyStore()

        guard let keyStoreID = keyStore.id else {
            throw Error.invalidData
        }

        var account = Account(
            accountIndex: nil,
            address: "0x18A25e76658ce696cF263FDec6434Be2BfDdb89A",
            blockchain: .evm(.ethereum(.mainnet)),
            derivationPath: nil,
            keyStoreId: keyStoreID,
            name: "Ethereum Mainnet Token Balance Watch-Only"
        )
        account.id = try await databaseService.insertAccount(account, keyStore: keyStore)

        let service = TransactionSyncService(databaseService: databaseService)
        await service.start(account)

        defer {
            Task {
                await service.stop(account)
            }
        }

        guard let accountID = account.id else {
            throw Error.invalidData
        }

        let backfillDeadline = ContinuousClock.now.advanced(by: .seconds(120))

        while ContinuousClock.now < backfillDeadline {
            let state = try await databaseService.transactionSyncState(accountId: accountID)

            if state.backfillComplete {
                break
            }

            try await Task.sleep(for: .milliseconds(500))
        }

        let completedState = try await databaseService.transactionSyncState(accountId: accountID)
        guard completedState.backfillComplete else {
            try await printTokenState(account: account, databaseService: databaseService)
            Issue.record("Ethereum mainnet backfill did not complete. Sync error: \(completedState.lastError ?? "none")")
            return
        }

        let balancesDeadline = ContinuousClock.now.advanced(by: .seconds(30))

        while ContinuousClock.now < balancesDeadline {
            if try await databaseService.fetchBalances(accountId: accountID).count > 30 {
                try await printTokenState(account: account, databaseService: databaseService)
                return
            }

            try await Task.sleep(for: .milliseconds(500))
        }

        let balances = try await databaseService.fetchBalances(accountId: accountID)
        try await printTokenState(account: account, databaseService: databaseService)
        #expect(balances.count > 30, "Expected more than 30 token balances, found \(balances.count).")
    }

    @Test
    func resolvesBlockscoutSourcesForSupportedEVMNetworks() {
        let defaultSource = BlockscoutTransactionHistorySource()

        #expect(defaultSource.supports(.evm(.arbitrum(.mainnet))))
        #expect(defaultSource.supports(.evm(.arbitrum(.sepolia))))
        #expect(!defaultSource.supports(.evm(.bsc(.mainnet))))
        #expect(defaultSource.supports(.evm(.ethereum(.mainnet))))
        #expect(defaultSource.supports(.evm(.ethereum(.sepolia))))

        let customEndpoint = URL(string: "https://explorer.example.com/api/v2")!
        let customSource = BlockscoutTransactionHistorySource(apiBaseURLs: [
            56: customEndpoint,
            31337: customEndpoint
        ])

        #expect(customSource.supports(.evm(.bsc(.mainnet))))
        #expect(customSource.supports(.evm(.custom(31337))))

        let suiArchiveSource = SuiArchiveTransactionHistorySource()
        #expect(suiArchiveSource.supports(.sui(.mainnet)))
        #expect(suiArchiveSource.supports(.sui(.testnet)))
    }

    @Test
    func resolvesEtherscanSourceOnlyWithAPIKey() {
        let suiteName = "EtherscanTransactionHistorySourceTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Could not create test UserDefaults suite.")
            return
        }

        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let source = EtherscanTransactionHistorySource(userDefaults: defaults)
        let supportedBlockchains: [WKBlockchain] = [
            .evm(.arbitrum(.mainnet)),
            .evm(.arbitrum(.sepolia)),
            .evm(.bsc(.mainnet)),
            .evm(.bsc(.testnet)),
            .evm(.ethereum(.mainnet)),
            .evm(.ethereum(.sepolia))
        ]

        for blockchain in supportedBlockchains {
            #expect(!source.supports(blockchain))
        }

        defaults.set("test-key", forKey: EtherscanTransactionHistorySource.apiKeyDefaultsKey)

        for blockchain in supportedBlockchains {
            #expect(source.supports(blockchain))
        }

        #expect(!source.supports(.evm(.custom(31337))))
        #expect(!source.supports(.sui(.mainnet)))
    }

    @Test
    func syncsWatchOnlySuiMainnetArchivedTransactions() async throws {
        let address = "0xa9ec9ac3016275c342c1a70c0d0963ada7065e4bf3500865f67a0fc42b0ec3c4"
        let databaseService = try makeDatabaseService()
        let keyStore = try await databaseService.watchOnlyKeyStore()

        guard let keyStoreID = keyStore.id else {
            throw Error.invalidData
        }

        var account = Account(
            accountIndex: nil,
            address: address,
            blockchain: .sui(.mainnet),
            derivationPath: nil,
            keyStoreId: keyStoreID,
            name: "Sui Mainnet Archived Watch-Only"
        )

        account.id = try await databaseService.insertAccount(account, keyStore: keyStore)

        let service = TransactionSyncService(databaseService: databaseService)
        await service.start(account)

        defer {
            Task {
                await service.stop(account)
            }
        }

        guard let accountID = account.id else {
            throw Error.invalidData
        }

        let deadline = ContinuousClock.now.advanced(by: .seconds(50))

        while ContinuousClock.now < deadline {
            if !(try await databaseService.fetchTransactions(accountId: accountID)).isEmpty {
                return
            }

            try await Task.sleep(for: .milliseconds(500))
        }

        let transactions = try await databaseService.fetchTransactions(accountId: accountID)
        let syncState = try await databaseService.transactionSyncState(accountId: accountID)

        #expect(
            !transactions.isEmpty,
            "No archived Sui mainnet transactions were saved for \(account.address). Sync error: \(syncState.lastError ?? "none")"
        )
    }

    @Test
    // swiftlint:disable:next function_body_length
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
// swiftlint:enable type_body_length

private extension TransactionSyncServiceTests {
    func printTokenState(account: Account, databaseService: DatabaseService) async throws {
        guard let accountID = account.id else {
            throw Error.invalidData
        }

        let balances = try await databaseService.fetchBalances(accountId: accountID)
        let tokens = try await databaseService.fetchTokens(blockchain: account.blockchain)
        let transactions = try await databaseService.fetchTransactions(accountId: accountID)
        let linkedTokens = Set(transactions.flatMap(\.effects).compactMap(\.balance).compactMap(\.token.address))
        let transferredTokens = Set(transactions.lazy.flatMap(\.effects).compactMap { effect in
            effect.kind == .tokenTransfer ? effect.assetIdentifier : nil
        })

        printDebug("Stored tokens (\(tokens.count)): \(tokenList(tokens))")
        printDebug("Balances (\(balances.count)): \(tokenList(balances.map(\.token)))")
        printDebug("Token-transfer effects (\(transferredTokens.count)): \(transferredTokens.sorted().joined(separator: ", "))")
        printDebug("Transaction-linked tokens (\(linkedTokens.count)): \(linkedTokens.sorted().joined(separator: ", "))")
    }

    func tokenList(_ tokens: [Token]) -> String {
        tokens
            .sorted { ($0.symbol, $0.address ?? "") < ($1.symbol, $1.address ?? "") }
            .map { token in
                "\(token.symbol) [\(token.address ?? "native")]"
            }
            .joined(separator: ", ")
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

    func sendNativeEthereumTransfer(
        from senderIndex: UInt64,
        to recipientIndex: UInt64,
        value: BigUInt
    ) async throws -> String {
        let recipient = try ethereumSigner(at: recipientIndex).address()
        let sender = try ethereumSigner(at: senderIndex)

        let hash = try await anvilNode.send(
            signer: sender,
            to: recipient,
            value: value,
            gasLimit: 21_000
        )

        _ = try await anvilNode.waitForReceipt(hash)

        return hash
    }

    func waitForEthereumTransactions(_ identifiers: Set<String>, timeout: Duration) async throws {
        let expected = try Dictionary(uniqueKeysWithValues: ethereumAccounts.map { account in
            (try requiredID(account), identifiers)
        })

        try await waitForTransactions(expected, timeout: timeout)
    }

    func waitForSuiTransactions(_ identifiers: Set<String>, timeout: Duration) async throws {
        let expected = try Dictionary(uniqueKeysWithValues: suiAccounts.map { account in
            (try requiredID(account), identifiers)
        })

        try await waitForTransactions(expected, timeout: timeout)
    }

    func waitForTransactions(
        _ expected: [PersistentIdentifier: Set<String>], timeout: Duration = .seconds(60)
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)

        while ContinuousClock.now < deadline {
            var allTransactionsPresent = true

            for (accountID, identifiers) in expected {
                let transactions = try await databaseService.fetchTransactions(accountId: accountID)
                let savedIdentifiers = Set(transactions.map(\.stableId))

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
            let savedIdentifiers = Set(transactions.map(\.stableId))

            missing.append(contentsOf: identifiers.filter { identifier in
                !savedIdentifiers.contains { $0.hasSuffix("|\(identifier)") }
            })
        }

        throw TransactionSyncTestError.missingTransactions(missing)
    }

    func broadcastEthereumTransactions() async throws -> [String] {
        let firstSigner = try ethereumSigner(at: 0)
        let secondSigner = try ethereumSigner(at: 1)
        let firstAddress = try firstSigner.address()
        let secondAddress = try secondSigner.address()

        try await fundEthereumAccounts()

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

    func fundEthereumAccounts() async throws {
        let balance = BigUInt(10_000_000_000_000_000_000)

        for index in ethereumAccounts.indices {
            try await anvilNode.setBalance(try ethereumSigner(at: UInt64(index)).address(), wei: balance)
        }
    }

    func broadcastSuiTransactions() async throws -> [String] {
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

    func sendSuiTransfer(from senderIndex: UInt64, to recipientIndex: UInt64) async throws -> String {
        let client = SuiGRPCClient(host: "127.0.0.1", port: Int(suiNode.rpcPort), useTLS: false)
        let recipient = try suiSigner(at: recipientIndex).address()
        let sender = try suiSigner(at: senderIndex)

        return try await sendSui(client: client, signer: sender, recipient: recipient)
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
} // swiftlint:disable:this file_length
