// Tests for CardanoDappProvider. Signing is local (software key) and Blockfrost
// is stubbed, so every CIP-30 method runs offline.

import Foundation
import Testing
import WalletKit
@testable import ReefrWallet

private actor CardanoRecordingApproving: DappApproving {
    let result: DappApprovalResult
    private(set) var requests: [DappApprovalRequest] = []
    /// Runs while the prompt is "open", before the user's answer returns.
    private let whileOpen: (@Sendable () async -> Void)?

    init(result: DappApprovalResult, whileOpen: (@Sendable () async -> Void)? = nil) {
        self.result = result
        self.whileOpen = whileOpen
    }

    func approve(_ request: DappApprovalRequest) async -> DappApprovalResult {
        requests.append(request)
        await whileOpen?()
        return result
    }
}

struct CardanoDappProviderFixture {
    let account: ReefrWallet.Account
    let descriptor: CardanoAccountDescriptor
    let provider: CardanoDappProvider
    let session: DappSession
    let signingService: DappSigningService
    let stub: CardanoStubURLProtocol.Stub
    let origin = "https://dapp.example"

    private let accountService: AccountService
    private let keyStore: KeyStore

    static let utxoHash = String(repeating: "07", count: 32)

    /// - Parameter routes: extra Blockfrost routes, by path under `/api/v0`.
    /// - Parameter utxos: replaces the account's default single UTxO (a Blockfrost JSON array).
    static func make(
        routes: [String: String] = [:],
        addresses: [String]? = nil,
        utxos: String? = nil
    ) async throws -> Self {
        let databaseService = try makeDatabaseService()
        let accountService = AccountService(databaseService: databaseService)
        let transactionService = TransactionService(databaseService: databaseService)
        let keyStore = try await makeLocalKeyStore(databaseService: databaseService, name: "Cardano Test Key Store")
        let account = try await accountService.makeAccount(.cardano(.preprod), keyStore: keyStore)
        let descriptor = try CardanoAccountDescriptor(string: account.address)

        var allRoutes = routes
        let utxo = """
        [{"address":"\(descriptor.receiveAddress.string)",
          "amount":[{"unit":"lovelace","quantity":"5000000"}],
          "output_index":0,"tx_hash":"\(utxoHash)"}]
        """
        allRoutes["/api/v0/accounts/\(descriptor.stakeAddress)/utxos"] = allRoutes[
            "/api/v0/accounts/\(descriptor.stakeAddress)/utxos"
        ] ?? utxos ?? utxo
        let known = addresses ?? [descriptor.receiveAddress.string]
        allRoutes["/api/v0/accounts/\(descriptor.stakeAddress)/addresses"] = allRoutes[
            "/api/v0/accounts/\(descriptor.stakeAddress)/addresses"
        ] ?? "[" + known.map { #"{"address":"\#($0)"}"# }.joined(separator: ",") + "]"
        allRoutes["/api/v0/epochs/latest/parameters"] = """
        {"coins_per_utxo_size":4310,"key_deposit":2000000,"max_tx_size":16384,"max_val_size":5000,
         "min_fee_a":44,"min_fee_b":155381,"pool_deposit":500000000}
        """
        let stub = CardanoStubURLProtocol.make(routes: allRoutes)

        let session = DappSession(origin: "https://dapp.example")
        await session.setActiveAccount(account)

        return Self(
            account: account,
            descriptor: descriptor,
            provider: CardanoDappProvider(makeClient: { _ in
                CardanoClient(endpoint: stub.endpoint, projectId: "project-id", session: stub.session)
            }),
            session: session,
            signingService: DappSigningService(transactionService: transactionService),
            stub: stub,
            accountService: accountService,
            keyStore: keyStore
        )
    }

    func context(approving: any DappApproving) -> DappRequestContext {
        DappRequestContext(origin: origin, session: session, approving: approving, signingService: signingService)
    }

    func enable() async throws {
        _ = try await provider.handle(
            method: "enable",
            params: .array([]),
            context: context(approving: CardanoRecordingApproving(result: .approved))
        )
    }

    /// A second Cardano account in the same key store.
    func makeOtherAccount() async throws -> ReefrWallet.Account {
        try await accountService.makeAccount(
            .cardano(.preprod),
            keyStore: keyStore,
            derivationPath: DerivationPath(string: "m/1852'/1815'/1'")
        )
    }

    /// A transaction spending this account's UTxO, as a dapp would send it: no witnesses.
    func unsignedTransaction() async throws -> Data {
        let client = CardanoClient(endpoint: stub.endpoint, projectId: "project-id", session: stub.session)
        let envelope = try await CardanoTransactionBuilder(client: client).buildTransfer(
            sender: .account(descriptor),
            recipient: .recipient(try descriptor.address(role: 0, index: 1)),
            amount: 1_000_000,
            token: nil,
            options: []
        )
        let unsigned = try JSONDecoder().decode(CardanoUnsignedTransaction.self, from: envelope)

        return Data([0x84]) + unsigned.transactionBody + Data([0xA0, 0xF5, 0xF6])
    }
}

/// The CIP-30 error `body` throws, or `nil`.
func cardanoError(_ body: () async throws -> JSONValue) async -> CardanoDappError? {
    do {
        _ = try await body()
        return nil
    } catch DappError.cardano(let error) {
        return error
    } catch {
        Issue.record("unexpected error: \(error)")
        return nil
    }
}

struct CardanoDappProviderTests {
    private func call(
        _ fixture: CardanoDappProviderFixture,
        _ method: String,
        _ params: [JSONValue] = [],
        approving: any DappApproving = CardanoRecordingApproving(result: .approved)
    ) async throws -> JSONValue {
        try await fixture.provider.handle(
            method: method,
            params: .array(params),
            context: fixture.context(approving: approving)
        )
    }

    // MARK: Connection

    @Test func enablePromptsOnceThenRemembersThePermission() async throws {
        let fixture = try await CardanoDappProviderFixture.make()
        let approving = CardanoRecordingApproving(result: .approved)

        #expect(try await call(fixture, "isEnabled", approving: approving) == .bool(false))
        #expect(try await call(fixture, "enable", approving: approving) == .bool(true))
        #expect(try await call(fixture, "enable", approving: approving) == .bool(true))
        #expect(try await call(fixture, "isEnabled", approving: approving) == .bool(true))
        #expect(await approving.requests.count == 1)
    }

    @Test func aRejectedEnableIsRefused() async throws {
        let fixture = try await CardanoDappProviderFixture.make()

        let error = await cardanoError {
            try await call(fixture, "enable", approving: CardanoRecordingApproving(result: .rejected))
        }

        #expect(error == .refused)
        #expect(error?.wire == .object(["code": .number(-3), "info": .string("The request was refused.")]))
    }

    @Test func callsBeforeEnableFailWithAccountChange() async throws {
        let fixture = try await CardanoDappProviderFixture.make()

        let error = await cardanoError { try await call(fixture, "getNetworkId") }

        #expect(error == .accountChanged)
    }

    @Test func switchingAccountsRequiresEnablingAgain() async throws {
        let fixture = try await CardanoDappProviderFixture.make()
        try await fixture.enable()
        let other = try await fixture.makeOtherAccount()

        // The session carries the permission to the new account, but the page enabled the first.
        await fixture.session.setActiveAccount(other)
        let error = await cardanoError { try await call(fixture, "getBalance") }

        #expect(error == .accountChanged)
    }

    // MARK: Reads

    @Test func networkExtensionsAndAddressesAreHex() async throws {
        let fixture = try await CardanoDappProviderFixture.make()
        try await fixture.enable()

        #expect(try await call(fixture, "getNetworkId") == .number(0))
        #expect(try await call(fixture, "getExtensions") == .array([]))

        let change = try await call(fixture, "getChangeAddress")
        let expected = try cardanoAddressBytes(fixture.descriptor.receiveAddress.string).map { String(format: "%02x", $0) }
            .joined()
        #expect(change == .string(expected))

        let reward = try await call(fixture, "getRewardAddresses")
        #expect(reward.arrayValue?.count == 1)
    }

    @Test func usedAndUnusedAddressesFollowTheChainHistory() async throws {
        let fixture = try await CardanoDappProviderFixture.make()
        try await fixture.enable()

        let used = try await call(fixture, "getUsedAddresses")
        let unused = try await call(fixture, "getUnusedAddresses")

        #expect(used.arrayValue?.count == 1)
        #expect(unused.arrayValue?.count == 1)
        #expect(used != unused)
    }

    @Test func paginationIsZeroIndexedAndOutOfRangeReportsTheTotal() async throws {
        let fixture = try await CardanoDappProviderFixture.make()
        try await fixture.enable()

        let first = try await call(fixture, "getUsedAddresses", [.object(["page": .number(0), "limit": .number(1)])])
        #expect(first.arrayValue?.count == 1)

        let error = await cardanoError {
            try await call(fixture, "getUsedAddresses", [.object(["page": .number(1), "limit": .number(1)])])
        }
        #expect(error == .paginate(maxSize: 1))
        #expect(error?.wire == .object(["maxSize": .number(1)]))

        let bad = await cardanoError {
            try await call(fixture, "getUsedAddresses", [.object(["page": .number(-1), "limit": .number(1)])])
        }
        guard case .invalidRequest = bad else {
            Issue.record("expected invalidRequest, got \(String(describing: bad))")
            return
        }
    }

    @Test func utxosAndBalanceAreCborHexAndUnreachableTargetsAreNull() async throws {
        let fixture = try await CardanoDappProviderFixture.make()
        try await fixture.enable()

        let utxos = try await call(fixture, "getUtxos")
        #expect(utxos.arrayValue?.count == 1)
        // 5 ADA as a bare coin Value: 1a004c4b40.
        #expect(try await call(fixture, "getBalance") == .string("1a004c4b40"))
        #expect(try await call(fixture, "getUtxos", [.string("1a004c4b40")]).arrayValue?.count == 1)
        // More than the account holds.
        #expect(try await call(fixture, "getUtxos", [.string("1a05f5e100")]) == .null)
    }

    // MARK: signTx

    @Test func signTxApprovesThenReturnsOnlyTheNewWitnesses() async throws {
        let fixture = try await CardanoDappProviderFixture.make()
        try await fixture.enable()
        let transaction = try await fixture.unsignedTransaction()
        let approving = CardanoRecordingApproving(result: .approved)

        let result = try await call(fixture, "signTx", [.string(transaction.cardanoHex), .bool(false)], approving: approving)

        let witnesses = try #require(result.stringValue)
        #expect(witnesses.hasPrefix("a100")) // {0: [vkey witnesses]} only
        let requests = await approving.requests
        guard case let .sendTransaction(_, namespace, _, .cardano(preview)) = try #require(requests.first) else {
            Issue.record("expected a Cardano transaction approval")
            return
        }
        #expect(namespace == .cardano)
        #expect(preview.signingPaths == [CardanoSigningPath(index: 0, role: 0)])
        #expect(preview.missingSignerCount == 0)
        #expect(preview.transaction.outputs.count == 2)
    }

    @Test func aDeclinedSignTxIsTxSignErrorTwo() async throws {
        let fixture = try await CardanoDappProviderFixture.make()
        try await fixture.enable()
        let transaction = try await fixture.unsignedTransaction()

        let error = await cardanoError {
            try await call(
                fixture,
                "signTx",
                [.string(transaction.cardanoHex)],
                approving: CardanoRecordingApproving(result: .rejected)
            )
        }

        guard case let .txSign(code, _) = error else {
            Issue.record("expected txSign, got \(String(describing: error))")
            return
        }
        #expect(code == .userDeclined)
        #expect(error?.wire.objectValue?["code"] == .number(2))
    }

    @Test func signTxFailsBeforePromptingWhenAnInputIsNotTheAccounts() async throws {
        // The account holds no UTxO, so it can't resolve what the transaction spends.
        let fixture = try await CardanoDappProviderFixture.make()
        let transaction = try await fixture.unsignedTransaction()
        let approving = CardanoRecordingApproving(result: .approved)
        let empty = try await CardanoDappProviderFixture.make(utxos: "[]")
        try await empty.enable()

        let error = await cardanoError {
            try await call(empty, "signTx", [.string(transaction.cardanoHex)], approving: approving)
        }

        guard case let .txSign(code, _) = error else {
            Issue.record("expected txSign, got \(String(describing: error))")
            return
        }
        #expect(code == .proofGeneration)
        #expect(await approving.requests.isEmpty)
    }

    @Test func malformedTransactionsAreRejected() async throws {
        let fixture = try await CardanoDappProviderFixture.make()
        try await fixture.enable()

        let notHex = await cardanoError { try await call(fixture, "signTx", [.string("zz")]) }
        let notCbor = await cardanoError { try await call(fixture, "signTx", [.string("deadbeef")]) }

        #expect(notHex == .invalidRequest("Expected a hex transaction."))
        guard case .txSign = notCbor else {
            Issue.record("expected txSign, got \(String(describing: notCbor))")
            return
        }
    }

    // MARK: signData

    @Test func signDataReturnsACoseSignatureAndKey() async throws {
        let fixture = try await CardanoDappProviderFixture.make()
        try await fixture.enable()
        let address = try cardanoAddressBytes(fixture.descriptor.receiveAddress.string).cardanoHex
        let approving = CardanoRecordingApproving(result: .approved)

        let result = try await call(
            fixture,
            "signData",
            [.string(address), .string(Data("hello".utf8).cardanoHex)],
            approving: approving
        )

        #expect(result["signature"]?.stringValue?.hasPrefix("84") == true)
        #expect(result["key"]?.stringValue?.hasPrefix("a4") == true)
        guard case let .signMessage(_, _, _, .cardanoCIP8(_, keyRole, payload)) = try #require(await approving.requests.first) else {
            Issue.record("expected a CIP-8 approval")
            return
        }
        #expect(keyRole == .payment)
        #expect(payload == Data("hello".utf8))
    }

    @Test func signDataForTheRewardAddressUsesTheStakeKey() async throws {
        let fixture = try await CardanoDappProviderFixture.make()
        try await fixture.enable()
        let reward = fixture.descriptor.stakeAddress
        let approving = CardanoRecordingApproving(result: .approved)

        _ = try await call(fixture, "signData", [.string(reward), .string("00")], approving: approving)

        guard case let .signMessage(_, _, _, .cardanoCIP8(_, keyRole, _)) = try #require(await approving.requests.first) else {
            Issue.record("expected a CIP-8 approval")
            return
        }
        #expect(keyRole == .stake)
    }

    @Test func signDataForAForeignAddressIsAddressNotPK() async throws {
        let fixture = try await CardanoDappProviderFixture.make()
        try await fixture.enable()
        let other = try await fixture.makeOtherAccount()
        let foreign = try CardanoAccountDescriptor(string: other.address).receiveAddress.string
        let approving = CardanoRecordingApproving(result: .approved)

        let error = await cardanoError {
            try await call(fixture, "signData", [.string(foreign), .string("00")], approving: approving)
        }

        guard case let .dataSign(code, _) = error else {
            Issue.record("expected dataSign, got \(String(describing: error))")
            return
        }
        #expect(code == .addressNotPK)
        #expect(await approving.requests.isEmpty)
    }

    @Test func aDeclinedSignDataIsDataSignErrorThree() async throws {
        let fixture = try await CardanoDappProviderFixture.make()
        try await fixture.enable()
        let address = fixture.descriptor.receiveAddress.string

        let error = await cardanoError {
            try await call(
                fixture,
                "signData",
                [.string(address), .string("00")],
                approving: CardanoRecordingApproving(result: .rejected)
            )
        }

        #expect(error?.wire.objectValue?["code"] == .number(3))
    }

    // MARK: submitTx

    @Test func submitTxPostsTheCborAndReturnsTheBodyHash() async throws {
        let fixture = try await CardanoDappProviderFixture.make(routes: ["/api/v0/tx/submit": "\"ignored\""])
        try await fixture.enable()
        let transaction = try await fixture.unsignedTransaction()

        let result = try await call(fixture, "submitTx", [.string(transaction.cardanoHex)])

        #expect(result.stringValue?.count == 64)
        #expect(fixture.stub.requestCount(path: "/api/v0/tx/submit") == 1)
    }

    @Test func aRefusedSubmissionIsTxSendError() async throws {
        let stub = try await CardanoDappProviderFixture.make()
        try await stub.enable()
        let transaction = try await stub.unsignedTransaction()

        // /tx/submit is not routed, so the stub answers 404.
        let error = await cardanoError { try await call(stub, "submitTx", [.string(transaction.cardanoHex)]) }

        guard case .txSend = error else {
            Issue.record("expected txSend, got \(String(describing: error))")
            return
        }
    }

    @Test func unknownMethodsAreInvalidRequests() async throws {
        let fixture = try await CardanoDappProviderFixture.make()
        try await fixture.enable()

        let error = await cardanoError { try await call(fixture, "getCollateral") }

        guard case .invalidRequest = error else {
            Issue.record("expected invalidRequest, got \(String(describing: error))")
            return
        }
    }
}

// MARK: - Approval integrity

/// Navigation or an account switch while the sheet is open must not reach the
/// key: the approved request is re-checked right before signing.
struct DappApprovalIntegrityTests {
    @Test func switchingAccountsWhileSignTxIsOpenDoesNotSign() async throws {
        let fixture = try await CardanoDappProviderFixture.make()
        try await fixture.enable()
        let transaction = try await fixture.unsignedTransaction()
        let other = try await fixture.makeOtherAccount()
        let session = fixture.session
        let approving = CardanoRecordingApproving(result: .approved, whileOpen: { await session.setActiveAccount(other) })

        let error = await cardanoError {
            try await fixture.provider.handle(
                method: "signTx",
                params: .array([.string(transaction.cardanoHex)]),
                context: fixture.context(approving: approving)
            )
        }

        #expect(error == .accountChanged)
    }

    @Test func navigatingWhileSignDataIsOpenDoesNotSign() async throws {
        let fixture = try await CardanoDappProviderFixture.make()
        try await fixture.enable()
        let session = fixture.session
        let approving = CardanoRecordingApproving(
            result: .approved,
            whileOpen: { await session.updateOrigin("https://other.example") }
        )

        let error = await cardanoError {
            try await fixture.provider.handle(
                method: "signData",
                params: .array([.string(fixture.descriptor.receiveAddress.string), .string("00")]),
                context: fixture.context(approving: approving)
            )
        }

        #expect(error == .accountChanged)
    }

    @Test func revokingTheSessionPermissionWhileOpenDoesNotSign() async throws {
        let fixture = try await CardanoDappProviderFixture.make()
        try await fixture.enable()
        let session = fixture.session
        let approving = CardanoRecordingApproving(result: .approved, whileOpen: { await session.revokePermission(.cardano) })

        let error = await cardanoError {
            try await fixture.provider.handle(
                method: "signData",
                params: .array([.string(fixture.descriptor.receiveAddress.string), .string("00")]),
                context: fixture.context(approving: approving)
            )
        }

        #expect(error == .accountChanged)
    }

    @Test func authorizeRejectsAChangedOriginAccountOrPermission() async throws {
        let fixture = try await CardanoDappProviderFixture.make()
        try await fixture.enable()
        let session = fixture.session

        try await session.authorize(.cardano, origin: fixture.origin, account: fixture.account)

        await #expect(throws: DappError.self) {
            try await session.authorize(.cardano, origin: "https://other.example", account: fixture.account)
        }

        await session.revokePermission(.cardano)
        await #expect(throws: DappError.self) {
            try await session.authorize(.cardano, origin: fixture.origin, account: fixture.account)
        }
    }
}
