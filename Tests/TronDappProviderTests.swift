// Tests for TronDappProvider. Signing is local (software key), so
// hand-encoded `raw_data` protobufs exercise validation, preview, and
// signing offline. `nodeRequest`'s network call isn't covered; its path
// policy (`nodeRequestTarget`) is.

import Foundation
import Testing
import WalletKit
@testable import ReefrWallet

/// Records each approval request and answers with a preset result.
private actor TronRecordingApproving: DappApproving {
    let result: DappApprovalResult
    private(set) var requests: [DappApprovalRequest] = []

    init(result: DappApprovalResult) {
        self.result = result
    }

    func approve(_ request: DappApprovalRequest) async -> DappApprovalResult {
        requests.append(request)
        return result
    }
}

private struct TronDappProviderFixture {
    let provider: TronDappProvider
    let session: DappSession
    let signingService: DappSigningService
    let account: ReefrWallet.Account
    let origin = "https://dapp.example"

    static func make() async throws -> TronDappProviderFixture {
        let databaseService = try makeDatabaseService()
        let accountService = AccountService(databaseService: databaseService)
        let transactionService = TransactionService(databaseService: databaseService)
        let keyStore = try await makeLocalKeyStore(
            databaseService: databaseService,
            name: "Tron Local Test Key Store"
        )

        let account = try await accountService.makeAccount(.tron(.mainnet), keyStore: keyStore)

        let session = DappSession(origin: "https://dapp.example")
        await session.setActiveAccount(account)

        return TronDappProviderFixture(
            provider: TronDappProvider(
                clientProvider: BlockchainClientProvider(),
                transactionService: transactionService
            ),
            session: session,
            signingService: DappSigningService(transactionService: transactionService),
            account: account
        )
    }

    func context(approving: any DappApproving) -> DappRequestContext {
        DappRequestContext(origin: origin, session: session, approving: approving, signingService: signingService)
    }

    func connect() async throws {
        _ = try await provider.handle(
            method: "connect",
            params: .object([:]),
            context: context(approving: TronRecordingApproving(result: .approved))
        )
    }

    /// A `TransferContract` `raw_data` from `owner` (default: this account).
    func transferRawData(owner: String? = nil, amount: UInt64 = 1_000_000) throws -> Data {
        let ownerBytes = try TronAddress(string: owner ?? account.address).rawBytes
        let recipient = try TronAddress(string: "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t").rawBytes

        var transfer = Data()
        transfer.appendBytesField(1, ownerBytes)
        transfer.appendBytesField(2, recipient)
        transfer.appendVarintField(3, amount)

        var any = Data()
        any.appendBytesField(1, Data("type.googleapis.com/protocol.TransferContract".utf8))
        any.appendBytesField(2, transfer)

        var contract = Data()
        contract.appendVarintField(1, 1)
        contract.appendBytesField(2, any)

        var raw = Data()
        raw.appendBytesField(1, Data([0xe9, 0x42]))
        raw.appendBytesField(4, Data([0x63, 0x94, 0x74, 0x7d, 0xa9, 0xfe, 0xe4, 0x21]))
        raw.appendVarintField(8, 1_752_562_632_000)
        raw.appendBytesField(11, contract)
        raw.appendVarintField(14, 1_752_562_572_000)
        return raw
    }

    func signTransactionParams(_ raw: Data, txId: String? = nil) -> JSONValue {
        var transaction: [String: JSONValue] = ["raw_data_hex": .string(String(raw.hexEncoded.dropFirst(2)))]
        if let txId {
            transaction["txID"] = .string(txId)
        }

        return .object(["transaction": .object(transaction)])
    }
}

/// The `DappError` `body` throws, as text (`"unauthorized"`), or `nil`.
private func dappError(_ body: () async throws -> JSONValue) async -> String? {
    do {
        _ = try await body()
        return nil
    } catch {
        return String(describing: error)
    }
}

struct TronDappProviderTests {
    @Test
    func connectPromptsThenGrantsPermission() async throws {
        let fixture = try await TronDappProviderFixture.make()
        let approving = TronRecordingApproving(result: .approved)

        let result = try await fixture.provider.handle(
            method: "connect", params: .object([:]), context: fixture.context(approving: approving)
        )

        #expect(await fixture.session.isPermitted(.tron))
        #expect(await approving.requests.count == 1)
        let expectedHex = try TronAddress(string: fixture.account.address).rawBytes.hexEncoded.dropFirst(2)
        #expect(result["address"]?.stringValue == fixture.account.address)
        #expect(result["hex"]?.stringValue == String(expectedHex))
    }

    @Test
    func onlyIfTrustedConnectFailsWithoutPrompting() async throws {
        let fixture = try await TronDappProviderFixture.make()
        let approving = TronRecordingApproving(result: .approved)

        #expect(await dappError {
            try await fixture.provider.handle(
                method: "connect",
                params: .object(["onlyIfTrusted": .bool(true)]),
                context: fixture.context(approving: approving)
            )
        } == "unauthorized")
        #expect(await approving.requests.isEmpty)
    }

    @Test
    func signTransactionPreviewsAndSignsTheDecodedBytes() async throws {
        let fixture = try await TronDappProviderFixture.make()
        try await fixture.connect()
        let approving = TronRecordingApproving(result: .approved)
        let raw = try fixture.transferRawData(amount: 2_500_000)
        let txId = try TronRawTransaction(rawBytes: raw).txId

        let result = try await fixture.provider.handle(
            method: "signTransaction",
            params: fixture.signTransactionParams(raw, txId: txId.hexEncoded),
            context: fixture.context(approving: approving)
        )

        #expect(result["signature"]?.stringValue?.count == 130)

        guard case let .sendTransaction(_, .tron, _, .tron(preview)) = await approving.requests.first else {
            Issue.record("expected a Tron transaction approval")
            return
        }

        #expect(preview.transaction.rawBytes == raw)
        guard case let .transfer(_, _, amount) = preview.transaction.contract else {
            Issue.record("expected a transfer")
            return
        }
        #expect(amount == 2_500_000)
    }

    @Test
    func signTransactionRejectsAnotherOwnerBeforePrompting() async throws {
        let fixture = try await TronDappProviderFixture.make()
        try await fixture.connect()
        let approving = TronRecordingApproving(result: .approved)
        let raw = try fixture.transferRawData(owner: "TMVQGm1qAQYVdetCeGRRkTWYYrLXuHK2HC")

        #expect(await dappError {
            try await fixture.provider.handle(
                method: "signTransaction",
                params: fixture.signTransactionParams(raw),
                context: fixture.context(approving: approving)
            )
        } == "unauthorized")
        #expect(await approving.requests.isEmpty)
    }

    @Test
    func signTransactionRejectsAMismatchedTxId() async throws {
        let fixture = try await TronDappProviderFixture.make()
        try await fixture.connect()
        let raw = try fixture.transferRawData()

        #expect(await dappError {
            try await fixture.provider.handle(
                method: "signTransaction",
                params: fixture.signTransactionParams(raw, txId: String(repeating: "0", count: 64)),
                context: fixture.context(approving: TronRecordingApproving(result: .approved))
            )
        } != nil)
    }

    @Test
    func signTransactionRequiresAConnection() async throws {
        let fixture = try await TronDappProviderFixture.make()

        #expect(await dappError {
            try await fixture.provider.handle(
                method: "signTransaction",
                params: fixture.signTransactionParams(try fixture.transferRawData()),
                context: fixture.context(approving: TronRecordingApproving(result: .approved))
            )
        } == "unauthorized")
    }

    @Test
    func signTransactionRejectionThrowsUserRejected() async throws {
        let fixture = try await TronDappProviderFixture.make()
        try await fixture.connect()

        #expect(await dappError {
            try await fixture.provider.handle(
                method: "signTransaction",
                params: fixture.signTransactionParams(try fixture.transferRawData()),
                context: fixture.context(approving: TronRecordingApproving(result: .rejected))
            )
        } == "userRejected")
    }

    @Test
    func signMessageReturnsA65ByteSignature() async throws {
        let fixture = try await TronDappProviderFixture.make()
        try await fixture.connect()
        let approving = TronRecordingApproving(result: .approved)

        let result = try await fixture.provider.handle(
            method: "signMessage",
            params: .object(["message": .string(Data("hello".utf8).hexEncoded)]),
            context: fixture.context(approving: approving)
        )

        #expect(result["signature"]?.stringValue?.hasPrefix("0x") == true)
        #expect(result["signature"]?.stringValue?.count == 132)
        guard case let .signMessage(_, .tron, _, .tronMessage(message)) = await approving.requests.first else {
            Issue.record("expected a Tron message approval")
            return
        }
        #expect(message == Data("hello".utf8))
    }

    @Test
    func sessionDidChangeReportsTheAccountOnlyWhenPermitted() async throws {
        let fixture = try await TronDappProviderFixture.make()

        let before = fixture.provider.sessionDidChange(await fixture.session.snapshot())
        #expect(before.first?.payload["account"] == .null)
        #expect(before.first?.payload["chainId"]?.stringValue == "0x2b6653dc")

        try await fixture.connect()

        let after = fixture.provider.sessionDidChange(await fixture.session.snapshot())
        #expect(after.first?.name == "change")
        #expect(after.first?.payload["account"]?["address"]?.stringValue == fixture.account.address)
    }

    @Test(arguments: [
        (BigUInt(20_000_000), "20.0 USDT"),
        (BigUInt(1_234_567), "1.234567 USDT"),
        (BigUInt(500), "0.0005 USDT"),
        (BigUInt(2).power(256) - 1, "Unlimited USDT")
    ])
    func tokenAmountsUseTheTokensDecimals(value: BigUInt, expected: String) {
        let word = value.serialize().leftPadded(toCount: 32)
        let token = TronTransactionPreview.Token(decimals: 6, symbol: "USDT")

        #expect(TronTransactionPreviewView.amount(word, token) == expected)
        #expect(TronTransactionPreviewView.amount(Data(count: 31) + [0x05], nil) == "5 (base units)")
    }

    @Test
    func wireErrorsUseTronLinkCodes() async throws {
        let fixture = try await TronDappProviderFixture.make()

        #expect(fixture.provider.wireError(.userRejected)["code"] == .number(4001))
        #expect(fixture.provider.wireError(.unauthorized)["code"] == .number(4100))
        #expect(fixture.provider.wireError(.invalidParams("x"))["code"] == .number(-32602))
    }

    @Test(arguments: [
        ("wallet/getaccount", "post", true),
        ("/walletsolidity/gettransactioninfobyid", "post", true),
        ("wallet/getnowblock", "get", true),
        ("v1/contracts/TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t/events", "get", true),
        ("v1/accounts/TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t", "post", false),
        ("wallet/../admin", "post", false),
        ("https://evil.example/wallet/getaccount", "get", false),
        ("jsonrpc", "post", false),
        ("wallet/getaccount", "delete", false)
    ])
    func nodeRequestPathPolicy(path: String, method: String, allowed: Bool) {
        let params = JSONValue.object(["path": .string(path), "method": .string(method), "payload": .object([:])])
        let isAllowed = (try? TronDappProvider.nodeRequestTarget(params)) != nil
        #expect(isAllowed == allowed, "\(method) \(path)")
    }

    @Test
    func nodeRequestEncodesGetPayloadAsQueryAndPostPayloadAsBody() throws {
        let get = try TronDappProvider.nodeRequestTarget(.object([
            "path": .string("v1/blocks/1/events"),
            "method": .string("GET"),
            "payload": .object(["only_confirmed": .bool(true), "limit": .number(20)])
        ]))
        #expect(get.body == nil)
        #expect(get.query == [
            URLQueryItem(name: "limit", value: "20"),
            URLQueryItem(name: "only_confirmed", value: "true")
        ])

        let post = try TronDappProvider.nodeRequestTarget(.object([
            "path": .string("wallet/getaccount"),
            "method": .string("post"),
            "payload": .object(["visible": .bool(true)])
        ]))
        #expect(post.body.flatMap { try? JSONValue(data: $0) } == .object(["visible": .bool(true)]))
    }
}

private extension Data {
    func leftPadded(toCount count: Int) -> Data {
        Data(repeating: 0, count: Swift.max(0, count - self.count)) + self
    }

    mutating func appendVarint(_ value: UInt64) {
        var value = value
        while value >= 0x80 {
            append(UInt8(value & 0x7f) | 0x80)
            value >>= 7
        }

        append(UInt8(value))
    }

    mutating func appendVarintField(_ number: UInt64, _ value: UInt64) {
        appendVarint(number << 3)
        appendVarint(value)
    }

    mutating func appendBytesField(_ number: UInt64, _ value: Data) {
        appendVarint(number << 3 | 2)
        appendVarint(UInt64(value.count))
        append(value)
    }
}
