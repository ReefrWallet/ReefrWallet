// Tests for SuiDappProvider, mirroring EthereumDappProviderTests.swift's
// structure but without a live local Sui validator: `signTransaction`'s
// decode/approve/sign path is pure local cryptography (no RPC), so a
// syntactically self-consistent transaction (real sender, fabricated gas
// object reference) exercises it fully offline. `signAndExecuteTransaction`'s
// broadcast step (SuiGRPCClient.executeTransactionWithEffects) genuinely
// needs a live node and isn't covered here — only its shared
// validate-then-sign gate is (identical code path to signTransaction's).

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

struct SuiDappProviderTests {
    @Test
    func connectRequiresApprovalThenGrantsPermission() async throws {
        let fixture = try await SuiDappProviderFixture.make()
        let context = fixture.context(approving: StubApproving(result: .approved))

        #expect(await fixture.session.isPermitted(.sui) == false)

        let result = try await fixture.provider.handle(method: "connect", params: .object([:]), context: context)

        #expect(await fixture.session.isPermitted(.sui))
        guard
            let accounts = result["accounts"]?.arrayValue, accounts.count == 1,
            let address = accounts[0]["address"]?.stringValue,
            let chain = accounts[0]["chain"]?.stringValue,
            accounts[0]["publicKey"]?.stringValue != nil
        else {
            Issue.record("expected {accounts: [{address, publicKey, chain}]}, got \(result)")
            return
        }
        #expect(address == fixture.account.address)
        #expect(chain == "sui:testnet")
    }

    @Test
    func connectRejectionThrowsUserRejectedWithNoNumericWireCode() async throws {
        let fixture = try await SuiDappProviderFixture.make()
        let context = fixture.context(approving: StubApproving(result: .rejected))

        do {
            _ = try await fixture.provider.handle(method: "connect", params: .object([:]), context: context)
            Issue.record("expected connect to throw")
        } catch {
            let wireError = fixture.provider.wireError(error)
            #expect(wireError["code"] == nil)
            #expect(wireError["message"] != nil)
        }
        #expect(await fixture.session.isPermitted(.sui) == false)
    }

    /// Regression test for namespace-wide permission revocation: connect
    /// while account A is selected, switch to account B (permission
    /// carries forward — same key, user-chosen switch), disconnect while
    /// B is selected, then switch back to A. A must NOT be silently
    /// permitted again. Revoking only the currently-selected account's
    /// grant (the bug this fixes) would have left A's earlier,
    /// carried-forward grant intact.
    @Test
    func disconnectRevokesPermissionForEveryAccountNotJustTheCurrentlySelectedOne() async throws {
        let fixture = try await SuiDappProviderFixture.make()
        let accountService = AccountService(databaseService: fixture.databaseService)
        let accountB = try await accountService.makeAccount(.sui(.testnet), keyStore: fixture.keyStore)
        let context = fixture.context(approving: StubApproving(result: .approved))

        _ = try await fixture.provider.handle(method: "connect", params: .object([:]), context: context)
        #expect(await fixture.session.isPermitted(.sui))

        await fixture.session.setActiveAccount(accountB)
        #expect(await fixture.session.isPermitted(.sui)) // carried forward

        _ = try await fixture.provider.handle(method: "disconnect", params: .object([:]), context: context)
        #expect(await fixture.session.isPermitted(.sui) == false)

        await fixture.session.setActiveAccount(fixture.account)
        #expect(await fixture.session.isPermitted(.sui) == false)
    }

    @Test
    func signPersonalMessageMatchesAnIndependentlyDerivedSigner() async throws {
        let fixture = try await SuiDappProviderFixture.make()
        let context = fixture.context(approving: StubApproving(result: .approved))
        _ = try await fixture.provider.handle(method: "connect", params: .object([:]), context: context)

        let message = Data("Example sui:signPersonalMessage message".utf8)
        let params = JSONValue.object([
            "message": .string(message.base64EncodedString()),
            "account": .object(["address": .string(fixture.account.address)])
        ])

        let result = try await fixture.provider.handle(method: "signPersonalMessage", params: params, context: context)
        guard
            let bytesBase64 = result["bytes"]?.stringValue, let signatureBase64 = result["signature"]?.stringValue,
            let signature = Data(base64Encoded: signatureBase64)
        else {
            Issue.record("expected {bytes, signature}, got \(result)")
            return
        }
        #expect(bytesBase64 == message.base64EncodedString())

        let independentSigner = try fixture.makeIndependentSigner()
        let expectedSignature = try await independentSigner.sign(message: .suiPersonal(message))
        #expect(signature == expectedSignature)
    }

    @Test
    func signTransactionProducesASignatureMatchingAnIndependentlyDerivedSigner() async throws {
        let fixture = try await SuiDappProviderFixture.make()
        let context = fixture.context(approving: StubApproving(result: .approved))
        _ = try await fixture.provider.handle(method: "connect", params: .object([:]), context: context)

        let transactionBytes = try fixture.validTransactionBytes()
        let params = JSONValue.object([
            "transactionBytes": .string(transactionBytes.base64EncodedString()),
            "account": .object(["address": .string(fixture.account.address)])
        ])

        let result = try await fixture.provider.handle(method: "signTransaction", params: params, context: context)
        guard
            let signatureBase64 = result["signature"]?.stringValue,
            let signature = Data(base64Encoded: signatureBase64)
        else {
            Issue.record("expected {bytes, signature}, got \(result)")
            return
        }

        let independentSigner = try fixture.makeIndependentSigner()
        let expectedSignature = try await independentSigner.sign(transaction: transactionBytes)
        #expect(signature == expectedSignature)
    }

    /// The core correctness fix under review: a transaction whose
    /// decoded sender doesn't match the authorized account must be
    /// rejected outright, before ever reaching the signer — not signed
    /// on the strength of a raw-bytes fallback.
    @Test
    func signTransactionRejectsASenderMismatchBeforeSigning() async throws {
        let fixture = try await SuiDappProviderFixture.make()
        let context = fixture.context(approving: StubApproving(result: .approved))
        _ = try await fixture.provider.handle(method: "connect", params: .object([:]), context: context)

        let attackerSender = try SuiAddress(rawBytes: Data(repeating: 0x99, count: 32))
        let recipient = try SuiAddress(rawBytes: Data(repeating: 0x42, count: 32))
        let gasCoin = SuiObjectReference(
            objectId: Data(repeating: 0x11, count: 32), version: 1, digest: Data(repeating: 0x22, count: 32)
        )

        let mismatchedTransaction = UnsignedSuiTransaction(
            sender: attackerSender, transfers: [(recipient: recipient, amount: 1000)],
            gasPayment: [gasCoin], gasOwner: attackerSender, gasPrice: 1000, gasBudget: 3_000_000
        )

        let params = JSONValue.object([
            "transactionBytes": .string(mismatchedTransaction.transactionDataBcs.base64EncodedString()),
            "account": .object(["address": .string(fixture.account.address)])
        ])

        do {
            _ = try await fixture.provider.handle(method: "signTransaction", params: params, context: context)
            Issue.record("expected signTransaction to reject a sender mismatch")
        } catch DappError.invalidParams(_) {
            // Expected.
        }
    }

    @Test
    func signTransactionRejectsASponsoredTransactionBeforeSigning() async throws {
        let fixture = try await SuiDappProviderFixture.make()
        let context = fixture.context(approving: StubApproving(result: .approved))
        _ = try await fixture.provider.handle(method: "connect", params: .object([:]), context: context)

        let sender = try SuiAddress(string: fixture.account.address)
        let sponsor = try SuiAddress(rawBytes: Data(repeating: 0x99, count: 32))
        let recipient = try SuiAddress(rawBytes: Data(repeating: 0x42, count: 32))
        let gasCoin = SuiObjectReference(
            objectId: Data(repeating: 0x11, count: 32), version: 1, digest: Data(repeating: 0x22, count: 32)
        )

        let sponsoredTransaction = UnsignedSuiTransaction(
            sender: sender, transfers: [(recipient: recipient, amount: 1000)],
            gasPayment: [gasCoin], gasOwner: sponsor, gasPrice: 1000, gasBudget: 3_000_000
        )

        let params = JSONValue.object([
            "transactionBytes": .string(sponsoredTransaction.transactionDataBcs.base64EncodedString()),
            "account": .object(["address": .string(fixture.account.address)])
        ])

        do {
            _ = try await fixture.provider.handle(method: "signTransaction", params: params, context: context)
            Issue.record("expected signTransaction to reject a sponsored transaction")
        } catch DappError.invalidParams(_) {
            // Expected.
        }
    }

    /// `sui.js` forwards `input.chain`; a mismatch between the requested
    /// chain and the authorized account's actual network must be
    /// rejected before signing — previously ignored entirely, which
    /// would have silently signed a testnet-selected account's
    /// transaction while the dapp believed it was on mainnet.
    @Test
    func signTransactionRejectsAChainMismatch() async throws {
        let fixture = try await SuiDappProviderFixture.make() // account is on .testnet
        let context = fixture.context(approving: StubApproving(result: .approved))
        _ = try await fixture.provider.handle(method: "connect", params: .object([:]), context: context)

        let transactionBytes = try fixture.validTransactionBytes()
        let params = JSONValue.object([
            "transactionBytes": .string(transactionBytes.base64EncodedString()),
            "account": .object(["address": .string(fixture.account.address)]),
            "chain": .string("sui:mainnet")
        ])

        do {
            _ = try await fixture.provider.handle(method: "signTransaction", params: params, context: context)
            Issue.record("expected signTransaction to reject a chain mismatch")
        } catch DappError.chainNotFound {
            // Expected.
        }
    }

    @Test
    func signTransactionAcceptsAMatchingChain() async throws {
        let fixture = try await SuiDappProviderFixture.make() // account is on .testnet
        let context = fixture.context(approving: StubApproving(result: .approved))
        _ = try await fixture.provider.handle(method: "connect", params: .object([:]), context: context)

        let transactionBytes = try fixture.validTransactionBytes()
        let params = JSONValue.object([
            "transactionBytes": .string(transactionBytes.base64EncodedString()),
            "account": .object(["address": .string(fixture.account.address)]),
            "chain": .string("sui:testnet")
        ])

        let result = try await fixture.provider.handle(method: "signTransaction", params: params, context: context)
        #expect(result["signature"]?.stringValue != nil)
    }

    @Test
    func signTransactionRejectsUndecodableBytes() async throws {
        let fixture = try await SuiDappProviderFixture.make()
        let context = fixture.context(approving: StubApproving(result: .approved))
        _ = try await fixture.provider.handle(method: "connect", params: .object([:]), context: context)

        let params = JSONValue.object([
            "transactionBytes": .string(Data([0xFF, 0xFF, 0xFF]).base64EncodedString()),
            "account": .object(["address": .string(fixture.account.address)])
        ])

        do {
            _ = try await fixture.provider.handle(method: "signTransaction", params: params, context: context)
            Issue.record("expected signTransaction to reject undecodable bytes")
        } catch DappError.invalidParams(_) {
            // Expected.
        }
    }

    @Test
    func unauthorizedAccountIsRejectedBeforeDecoding() async throws {
        let fixture = try await SuiDappProviderFixture.make()
        let context = fixture.context(approving: StubApproving(result: .approved))
        // Deliberately not connected.

        let params = JSONValue.object([
            "transactionBytes": .string(Data([0xFF]).base64EncodedString()),
            "account": .object(["address": .string(fixture.account.address)])
        ])

        do {
            _ = try await fixture.provider.handle(method: "signTransaction", params: params, context: context)
            Issue.record("expected signTransaction to reject an unauthorized account")
        } catch DappError.unauthorized {
            // Expected.
        }
    }
}

// MARK: - Fixture

struct SuiDappProviderFixture {
    let databaseService: DatabaseService
    let provider: SuiDappProvider
    let session: DappSession
    let signingService: DappSigningService
    let account: ReefrWallet.Account
    let keyStore: KeyStore
    let origin = "https://dapp.example"

    static func make(chainClient: FakeSuiDappChainQuerying? = nil) async throws -> SuiDappProviderFixture {
        let databaseService = try makeDatabaseService()
        let accountService = AccountService(databaseService: databaseService)
        let transactionService = TransactionService(databaseService: databaseService)
        let clientProvider = BlockchainClientProvider()

        let keyStore = try await makeLocalKeyStore(databaseService: databaseService, name: "Sui Local Test Key Store")
        let account = try await accountService.makeAccount(.sui(.testnet), keyStore: keyStore)

        let provider = SuiDappProvider(
            clientProvider: clientProvider,
            transactionService: transactionService,
            chainClient: chainClient.map { fake in { @Sendable _ in fake } }
        )

        let session = DappSession(origin: "https://dapp.example")
        await session.setActiveAccount(account)

        return SuiDappProviderFixture(
            databaseService: databaseService,
            provider: provider,
            session: session,
            signingService: DappSigningService(transactionService: transactionService),
            account: account,
            keyStore: keyStore
        )
    }

    func context(approving: any DappApproving) -> DappRequestContext {
        DappRequestContext(origin: origin, session: session, approving: approving, signingService: signingService)
    }

    /// A syntactically self-consistent Sui transaction with `account` as
    /// sender, for exercising `signTransaction`'s decode/sign path
    /// without a live node — the gas object reference is fabricated
    /// (not a real owned object), so this is signable but not actually
    /// broadcastable.
    func validTransactionBytes() throws -> Data {
        let sender = try SuiAddress(string: account.address)
        let recipient = try SuiAddress(rawBytes: Data(repeating: 0x42, count: 32))
        let gasCoin = SuiObjectReference(
            objectId: Data(repeating: 0x11, count: 32), version: 1, digest: Data(repeating: 0x22, count: 32)
        )

        let transaction = UnsignedSuiTransaction(
            sender: sender, transfers: [(recipient: recipient, amount: 1000)],
            gasPayment: [gasCoin], gasOwner: sender, gasPrice: 1000, gasBudget: 3_000_000
        )

        return transaction.transactionDataBcs
    }

    /// A `TransactionData::V1` blob with a single zero-argument
    /// `Command::MoveCall` (`0x2::clock::timestamp_ms`) — hand-assembled
    /// with ``BCS`` directly, since none of the `UnsignedSui*` builders
    /// produce a `MoveCall`. Exercises `SuiTransactionDataDecoder`'s
    /// MoveCall support end to end through the provider.
    func validMoveCallTransactionBytes() throws -> Data {
        let sender = try SuiAddress(string: account.address)
        let package = try SuiAddress(rawBytes: Data(repeating: 0, count: 31) + Data([0x02]))
        let gasCoin = SuiObjectReference(
            objectId: Data(repeating: 0x11, count: 32), version: 1, digest: Data(repeating: 0x22, count: 32)
        )

        var data = Data([0x00, 0x00]) // TransactionData::V1, ProgrammableTransaction
        data += BCS.uleb128(0) // inputs: none
        data += BCS.uleb128(1) // commands: one
        data.append(0x00) // Command::MoveCall
        data += package.rawBytes
        data += BCS.byteVector(Data("clock".utf8))
        data += BCS.byteVector(Data("timestamp_ms".utf8))
        data += BCS.uleb128(0) // typeArguments: none
        data += BCS.uleb128(0) // arguments: none
        data += sender.rawBytes
        data += BCS.uleb128(1) // gas payment: one coin
        data += gasCoin.objectId
        data += BCS.u64(gasCoin.version)
        data += BCS.byteVector(gasCoin.digest)
        data += sender.rawBytes // gas owner
        data += BCS.u64(1000) // gas price
        data += BCS.u64(3_000_000) // gas budget
        data.append(0x00) // TransactionExpiration::None
        return data
    }

    /// Re-derives `account`'s signer directly from the key store's seed,
    /// independently of the dapp-provider path — the same technique
    /// `TransactionService.makeSigner` itself uses, giving an
    /// independent check that the dapp bridge produces the same
    /// signature this account's real key would.
    func makeIndependentSigner() throws -> SuiPKeySigner {
        guard let derivationPathString = account.derivationPath, case let .sui(network) = account.blockchain else {
            throw Error.invalidData
        }

        let curve = account.signatureScheme ?? .ed25519
        let seed = try Seed(rawBytes: try keyStore.localSeed())
        let derivationPath = try DerivationPath(string: derivationPathString)
        let privateKey = try seed.masterKey(curve: curve).derive(derivationPath).privateKey()
        return try SuiPKeySigner(curve: curve, network: network, privateKey: privateKey, derivationPath: derivationPath)
    }
}
