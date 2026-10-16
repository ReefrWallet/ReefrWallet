// swiftlint:disable file_length
// Integration tests for EthereumDappProvider against a real, running
// local Ethereum node (Foundry's `anvil`) — see AnvilTestSupport.swift
// for the shared node/deployer/mock-ERC-20 setup. Exercises the dapp
// bridge's method table directly (bypassing WKWebView/WKScriptMessage,
// which DappBridgeTests.swift's dispatch-core tests already cover).

import BigInt
import Foundation
import Testing
import WalletKit
import WalletKitTesting
@testable import ReefrWallet

/// Answers every approval request immediately with a preset result.
private struct StubApproving: DappApproving {
    let result: DappApprovalResult

    func approve(_ request: DappApprovalRequest) async -> DappApprovalResult {
        result
    }
}

/// Navigates the session to another origin while the prompt is open, then
/// approves.
private struct NavigatingApproving: DappApproving {
    let session: DappSession
    let newOrigin: String

    func approve(_ request: DappApprovalRequest) async -> DappApprovalResult {
        await session.updateOrigin(newOrigin)
        return .approved
    }
}

@Suite(.timeLimit(.minutes(1)), .localNode)
struct EthereumDappProviderTests {
    @Test
    func chainIdAndBalancePassthroughReturnLiveNodeValues() async throws {
        let fixture = try await EthereumDappProviderFixture.make()
        defer { fixture.node.stop() }
        let context = fixture.context(approving: StubApproving(result: .approved))

        let chainIdResult = try await fixture.provider.handle(
            method: "eth_chainId", params: .array([]), context: context
        )
        #expect(chainIdResult == .string("0x" + String(fixture.node.chainId, radix: 16)))

        let balanceParams = JSONValue.array([.string(fixture.account.address), .string("latest")])
        let balanceResult = try await fixture.provider.handle(
            method: "eth_getBalance", params: balanceParams, context: context
        )

        guard case let .string(hex) = balanceResult, let balance = BigUInt(hex.dropFirst(2), radix: 16) else {
            Issue.record("expected a hex string balance, got \(balanceResult)")
            return
        }

        #expect(balance == fixture.nativeBalance)
    }

    @Test
    func accountsIsEmptyUntilConnectedThenReturnsTheSelectedAddress() async throws {
        let fixture = try await EthereumDappProviderFixture.make()
        defer { fixture.node.stop() }
        let context = fixture.context(approving: StubApproving(result: .approved))

        let before = try await fixture.provider.handle(method: "eth_accounts", params: .array([]), context: context)
        #expect(before == .array([]))

        let requestResult = try await fixture.provider.handle(
            method: "eth_requestAccounts", params: .array([]), context: context
        )
        #expect(requestResult == .array([.string(fixture.account.address)]))

        let after = try await fixture.provider.handle(method: "eth_accounts", params: .array([]), context: context)
        #expect(after == .array([.string(fixture.account.address)]))
    }

    @Test
    func personalSignAndTypedDataSignaturesMatchAnIndependentlyDerivedSigner() async throws {
        let fixture = try await EthereumDappProviderFixture.make()
        defer { fixture.node.stop() }
        let context = fixture.context(approving: StubApproving(result: .approved))
        _ = try await fixture.provider.handle(method: "eth_requestAccounts", params: .array([]), context: context)

        let independentSigner = try fixture.makeIndependentSigner()

        let message = "Example personal_sign message"
        let messageHex = "0x" + Data(message.utf8).hexEncoded
        let personalSignResult = try await fixture.provider.handle(
            method: "personal_sign",
            params: .array([.string(messageHex), .string(fixture.account.address)]),
            context: context
        )

        guard case let .string(signatureHex) = personalSignResult else {
            Issue.record("expected a signature hex string, got \(personalSignResult)")
            return
        }

        let expectedPersonalSignature = try await independentSigner.sign(message: .ethereumPersonal(Data(message.utf8)))
        #expect(signatureHex == "0x" + expectedPersonalSignature.hexEncoded)

        let typedDataJSON = """
        {"types":{"EIP712Domain":[{"name":"name","type":"string"},{"name":"chainId","type":"uint256"}], \
        "Mail":[{"name":"contents","type":"string"}]},"primaryType":"Mail", \
        "domain":{"name":"Reefr Test","chainId":\(fixture.node.chainId)},"message":{"contents":"hello"}}
        """
        let typedData = try JSONValue(data: Data(typedDataJSON.utf8))
        let signTypedDataResult = try await fixture.provider.handle(
            method: "eth_signTypedData_v4",
            params: .array([.string(fixture.account.address), typedData]),
            context: context
        )

        guard case let .string(typedDataSignatureHex) = signTypedDataResult else {
            Issue.record("expected a signature hex string, got \(signTypedDataResult)")
            return
        }

        let expectedTypedDataSignature = try await independentSigner.sign(
            message: .ethereumTypedData(json: typedDataJSON)
        )

        #expect(typedDataSignatureHex == "0x" + expectedTypedDataSignature.hexEncoded)
    }

    @Test
    func sendTransactionToMockUSDCProducesAConfirmedReceiptAndMovesTheBalance() async throws {
        let fixture = try await EthereumDappProviderFixture.make()
        defer { fixture.node.stop() }
        let context = fixture.context(approving: StubApproving(result: .approved))
        _ = try await fixture.provider.handle(method: "eth_requestAccounts", params: .array([]), context: context)

        let recipient = try EthereumAddress(publicKey: randomEthereumPrivateKey().publicKey)
        let transferAmount = BigUInt(25_000_000) // 25 mock USDC (6 decimals)
        let calldata = EthereumABI.encodeCall(
            selector: EthereumABI.selector("transfer(address,uint256)"),
            parameters: [.address(recipient), .uint256(transferAmount)]
        )

        let tx: JSONValue = .object([
            "from": .string(fixture.account.address),
            "to": .string(fixture.mockUSDCAddress.string),
            "value": .string("0x0"),
            "data": .string("0x" + calldata.hexEncoded)
        ])

        let result = try await fixture.provider.handle(
            method: "eth_sendTransaction", params: .array([tx]), context: context
        )

        guard case let .string(hash) = result else {
            Issue.record("expected a transaction hash, got \(result)")
            return
        }

        let receipt = try await fixture.node.waitForReceipt(hash)
        #expect(receipt.status == "0x1")

        let client = EthereumRPCClient(endpoint: fixture.node.endpoint, chainId: fixture.node.chainId)
        let recipientBalance = try await client.erc20Balance(token: fixture.mockUSDCAddress, owner: recipient)
        #expect(recipientBalance == transferAmount)
    }

    @Test
    func connectApprovalIsDiscardedWhenTheOriginChangedWhilePrompting() async throws {
        let fixture = try await EthereumDappProviderFixture.make()
        defer { fixture.node.stop() }
        let context = fixture.context(
            approving: NavigatingApproving(session: fixture.session, newOrigin: "https://b.example")
        )

        do {
            _ = try await fixture.provider.handle(method: "eth_requestAccounts", params: .array([]), context: context)
            Issue.record("expected eth_requestAccounts to throw")
        } catch {
            #expect(fixture.provider.wireError(error)["code"] == .number(4900))
        }

        #expect(await fixture.session.origin == "https://b.example")
        #expect(await fixture.session.isPermitted(.ethereum) == false)
    }

    @Test
    func sendTransactionPreviewsAndSignsTheDappGasOverrides() async throws {
        let fixture = try await EthereumDappProviderFixture.make()
        defer { fixture.node.stop() }
        try await fixture.connect()

        let approving = RecordingApproving(result: .approved)
        let hash = try await fixture.sendOverriddenTransfer(context: fixture.context(approving: approving))

        guard case let .sendTransaction(_, _, _, .ethereum(call, fees)) = approving.lastRequest else {
            Issue.record("expected an Ethereum sendTransaction approval")
            return
        }

        #expect(call.gasLimit == EthereumDappProviderFixture.overrideGasLimit)
        #expect(call.hasDappFeeOverrides)
        #expect(fees.ethereumMaxFee == EthereumDappProviderFixture.overrideMaxFee.description)
        #expect(fees.ethereumMaxPriorityFee == EthereumDappProviderFixture.overrideMaxPriorityFee.description)
        let maxCost = EthereumDappProviderFixture.overrideGasLimit * EthereumDappProviderFixture.overrideMaxFee
        #expect(fees.nativeFeeReserve == maxCost.description)

        let signed = try await fixture.signedTransaction(hash)
        #expect(signed.gas == EthereumDappProviderFixture.overrideGasLimit)
        #expect(signed.maxFeePerGas == EthereumDappProviderFixture.overrideMaxFee)
        #expect(signed.maxPriorityFeePerGas == EthereumDappProviderFixture.overrideMaxPriorityFee)
    }

    @Test
    func sendTransactionSignsTheUsersEditedFeesOverTheDapps() async throws {
        let fixture = try await EthereumDappProviderFixture.make()
        defer { fixture.node.stop() }
        try await fixture.connect()

        let editedMaxFee = BigUInt(50_000_000_000)
        let editedMaxPriorityFee = BigUInt(1_000_000_000)
        let edited = Fees(
            ethereumMaxFee: editedMaxFee.description, ethereumMaxPriorityFee: editedMaxPriorityFee.description
        )

        let hash = try await fixture.sendOverriddenTransfer(
            context: fixture.context(approving: StubApproving(result: .approvedWithFees(edited)))
        )

        let signed = try await fixture.signedTransaction(hash)
        #expect(signed.gas == EthereumDappProviderFixture.overrideGasLimit)
        #expect(signed.maxFeePerGas == editedMaxFee)
        #expect(signed.maxPriorityFeePerGas == editedMaxPriorityFee)
    }

    @Test
    func sendTransactionRejectsMalformedFieldsWithInvalidParams() async throws {
        let fixture = try await EthereumDappProviderFixture.make()
        defer { fixture.node.stop() }
        let context = fixture.context(approving: StubApproving(result: .approved))
        _ = try await fixture.provider.handle(method: "eth_requestAccounts", params: .array([]), context: context)

        let malformed: [(String, JSONValue)] = [
            ("value", .string("not-hex")), ("data", .string("0xabc")), ("gas", .number(123))
        ]

        for (key, bad) in malformed {
            let address = JSONValue.string(fixture.account.address)
            let tx: JSONValue = .object(["from": address, "to": address, key: bad])
            do {
                _ = try await fixture.provider.handle(
                    method: "eth_sendTransaction", params: .array([tx]), context: context
                )

                Issue.record("expected \(key) to be rejected")
            } catch {
                #expect(fixture.provider.wireError(error)["code"] == .number(-32602))
            }
        }
    }

    @Test
    func rejectingApprovalMapsToTheEip1193UserRejectedWireCode() async throws {
        let fixture = try await EthereumDappProviderFixture.make()
        defer { fixture.node.stop() }
        let context = fixture.context(approving: StubApproving(result: .rejected))

        do {
            _ = try await fixture.provider.handle(method: "eth_requestAccounts", params: .array([]), context: context)
            Issue.record("expected eth_requestAccounts to throw")
        } catch {
            #expect(fixture.provider.wireError(error)["code"] == .number(4001))
        }
    }

    @Test
    func unsupportedMethodMapsToTheEip1193UnsupportedMethodWireCode() async throws {
        let fixture = try await EthereumDappProviderFixture.make()
        defer { fixture.node.stop() }
        let context = fixture.context(approving: StubApproving(result: .approved))

        do {
            _ = try await fixture.provider.handle(
                method: "wallet_addEthereumChain", params: .array([]), context: context
            )

            Issue.record("expected an unsupportedMethod error")
        } catch {
            #expect(fixture.provider.wireError(error)["code"] == .number(4200))
        }
    }

    @Test
    func switchEthereumChainSwitchesToTheSiblingAccountAndCarriesForwardPermission() async throws {
        let fixture = try await EthereumDappProviderFixture.make()
        defer { fixture.node.stop() }
        let accountService = AccountService(databaseService: fixture.databaseService)
        let siblingChainId = fixture.node.chainId + 1
        let sibling = try await accountService.makeAccount(.evm(.custom(siblingChainId)), keyStore: fixture.keyStore)
        let context = fixture.context(approving: StubApproving(result: .approved))

        _ = try await fixture.provider.handle(method: "eth_requestAccounts", params: .array([]), context: context)
        #expect(await fixture.session.isPermitted(.ethereum))

        let switchParams = JSONValue.array([.object(["chainId": .string("0x" + String(siblingChainId, radix: 16))])])
        let result = try await fixture.provider.handle(
            method: "wallet_switchEthereumChain", params: switchParams, context: context
        )
        #expect(result == .null)
        #expect(await fixture.session.selectedAccount(.ethereum) == sibling)
        #expect(await fixture.session.isPermitted(.ethereum)) // carried forward
    }

    @Test
    func switchEthereumChainWithNoSiblingAccountThrowsChainNotFound() async throws {
        let fixture = try await EthereumDappProviderFixture.make()
        defer { fixture.node.stop() }
        let context = fixture.context(approving: StubApproving(result: .approved))
        _ = try await fixture.provider.handle(method: "eth_requestAccounts", params: .array([]), context: context)

        let unknownChainId = fixture.node.chainId + 1
        let switchParams = JSONValue.array([.object(["chainId": .string("0x" + String(unknownChainId, radix: 16))])])

        do {
            _ = try await fixture.provider.handle(
                method: "wallet_switchEthereumChain", params: switchParams, context: context
            )

            Issue.record("expected a chainNotFound error")
        } catch {
            #expect(fixture.provider.wireError(error)["code"] == .number(4902))
        }
    }

    @Test
    func switchEthereumChainBeforeRequestAccountsThrowsUnauthorized() async throws {
        let fixture = try await EthereumDappProviderFixture.make()
        defer { fixture.node.stop() }
        let accountService = AccountService(databaseService: fixture.databaseService)
        let siblingChainId = fixture.node.chainId + 1
        _ = try await accountService.makeAccount(.evm(.custom(siblingChainId)), keyStore: fixture.keyStore)
        let context = fixture.context(approving: StubApproving(result: .approved))
        let originalAccount = await fixture.session.selectedAccount(.ethereum)
        #expect(await !fixture.session.isPermitted(.ethereum))

        let switchParams = JSONValue.array([.object(["chainId": .string("0x" + String(siblingChainId, radix: 16))])])

        do {
            _ = try await fixture.provider.handle(
                method: "wallet_switchEthereumChain", params: switchParams, context: context
            )

            Issue.record("expected an unauthorized error")
        } catch DappError.unauthorized {
            // Expected.
        } catch {
            Issue.record("expected an unauthorized error, got \(error)")
        }

        #expect(await fixture.session.selectedAccount(.ethereum) == originalAccount)
    }

    @Test
    func switchEthereumChainOnANonEvmActiveAccountThrowsDisconnected() async throws {
        let fixture = try await EthereumDappProviderFixture.make()
        defer { fixture.node.stop() }
        let accountService = AccountService(databaseService: fixture.databaseService)
        let solanaAccount = try await accountService.makeAccount(.solana(.devnet), keyStore: fixture.keyStore)
        await fixture.session.setActiveAccount(solanaAccount)
        let context = fixture.context(approving: StubApproving(result: .approved))

        let switchParams = JSONValue.array([.object(["chainId": .string("0x1")])])

        do {
            _ = try await fixture.provider.handle(
                method: "wallet_switchEthereumChain", params: switchParams, context: context
            )

            Issue.record("expected a disconnected error")
        } catch {
            #expect(fixture.provider.wireError(error)["code"] == .number(4900))
        }
    }
}

// MARK: - Fixture

private struct EthereumDappProviderFixture {
    let node: EthereumNode
    let databaseService: DatabaseService
    let provider: EthereumDappProvider
    let session: DappSession
    let signingService: DappSigningService
    let account: ReefrWallet.Account
    let keyStore: KeyStore
    let mockUSDCAddress: EthereumAddress
    let nativeBalance: BigUInt
    let origin = "https://dapp.example"

    static func make() async throws -> EthereumDappProviderFixture {
        let node = try await startAnvilNode()
        let blockchain = Blockchain.evm(.custom(node.chainId))

        let databaseService = try makeDatabaseService()
        let accountService = AccountService(databaseService: databaseService)
        let transactionService = TransactionService(databaseService: databaseService)
        let feeEstimationService = FeeEstimationService()
        let clientProvider = BlockchainClientProvider()

        let keyStore = try await makeLocalKeyStore(databaseService: databaseService)
        let account = try await accountService.makeAccount(
            blockchain, keyStore: keyStore, rpcURLOverride: node.endpoint
        )

        let senderAddress = try EthereumAddress(string: account.address)
        let nativeBalance = BigUInt(10_000_000_000_000_000_000)
        try await node.setBalance(senderAddress, wei: nativeBalance)

        let deployer = try await makeFundedDeployer(node: node, blockchain: blockchain)
        let mockUSDCAddress = try await deployMockUSDC(deployer: deployer)
        try await mintMockUSDC(
            deployer: deployer, mockUSDCAddress: mockUSDCAddress, wallet: senderAddress, amount: BigUInt(1_000_000_000)
        )

        let provider = EthereumDappProvider(
            databaseService: databaseService,
            clientProvider: clientProvider,
            feeEstimationService: feeEstimationService,
            transactionService: transactionService
        )

        let session = DappSession(origin: "https://dapp.example")
        await session.setActiveAccount(account)

        return EthereumDappProviderFixture(
            node: node,
            databaseService: databaseService,
            provider: provider,
            session: session,
            signingService: DappSigningService(transactionService: transactionService),
            account: account,
            keyStore: keyStore,
            mockUSDCAddress: mockUSDCAddress,
            nativeBalance: nativeBalance
        )
    }

    static let overrideGasLimit = BigUInt(3_000_000)
    static let overrideMaxFee = BigUInt(100_000_000_000)
    static let overrideMaxPriorityFee = BigUInt(2_000_000_000)

    func context(approving: any DappApproving) -> DappRequestContext {
        DappRequestContext(origin: origin, session: session, approving: approving, signingService: signingService)
    }

    /// Sends 1 wei to a fresh address with dapp-supplied `gas`/fee caps;
    /// returns the transaction hash.
    func sendOverriddenTransfer(context: DappRequestContext) async throws -> String {
        let recipient = try EthereumAddress(publicKey: randomEthereumPrivateKey().publicKey)
        let tx: JSONValue = .object([
            "from": .string(account.address),
            "to": .string(recipient.string),
            "value": .string("0x1"),
            "gas": .string("0x" + String(Self.overrideGasLimit, radix: 16)),
            "maxFeePerGas": .string("0x" + String(Self.overrideMaxFee, radix: 16)),
            "maxPriorityFeePerGas": .string("0x" + String(Self.overrideMaxPriorityFee, radix: 16))
        ])

        let result = try await provider.handle(method: "eth_sendTransaction", params: .array([tx]), context: context)
        guard case let .string(hash) = result else {
            throw ReefrError.invalidData
        }

        _ = try await node.waitForReceipt(hash)
        return hash
    }

    func connect() async throws {
        let approving = StubApproving(result: .approved)
        _ = try await provider.handle(
            method: "eth_requestAccounts", params: .array([]), context: context(approving: approving)
        )
    }

    /// The gas fields of transaction `hash` as the node received them.
    func signedTransaction(_ hash: String) async throws -> SignedGasFields {
        let result = try await provider.handle(
            method: "eth_getTransactionByHash",
            params: .array([.string(hash)]),
            context: context(approving: StubApproving(result: .rejected))
        )

        func quantity(_ key: String) -> BigUInt? {
            result[key]?.stringValue.flatMap { BigUInt($0.dropFirst(2), radix: 16) }
        }

        return SignedGasFields(
            gas: quantity("gas"),
            maxFeePerGas: quantity("maxFeePerGas"),
            maxPriorityFeePerGas: quantity("maxPriorityFeePerGas")
        )
    }

    /// Re-derives `account`'s signer directly from the key store's seed,
    /// independently of the dapp-provider path — the same technique
    /// `TransactionService.makeSigner` itself uses, giving an
    /// independent check that the dapp bridge produces the same
    /// signature this account's real key would.
    func makeIndependentSigner() throws -> EthereumPKeySigner {
        guard case let .evm(chain) = account.blockchain, let derivationPathString = account.derivationPath else {
            throw ReefrError.invalidData
        }

        let seed = try Seed(rawBytes: try keyStore.localSeed())
        let derivationPath = try DerivationPath(string: derivationPathString)
        let privateKey = try seed.masterKey(curve: .secp256k1).derive(derivationPath).privateKey()
        return try EthereumPKeySigner(chainId: chain.chainId, privateKey: privateKey, derivationPath: derivationPath)
    }
}

private struct SignedGasFields {
    let gas: BigUInt?
    let maxFeePerGas: BigUInt?
    let maxPriorityFeePerGas: BigUInt?
}

private extension Data {
    var hexEncoded: String { map { String(format: "%02x", $0) }.joined() }
}
