// Native AptosDappProvider: permissions, fail-closed transaction validation,
// and AIP-62 message assembly. Offline: the chain ID is stubbed.

import Foundation
import Testing
import WalletKit
@testable import ReefrWallet

private actor RecordingApprover: DappApproving {
    private let result: DappApprovalResult
    private(set) var requests: [DappApprovalRequest] = []

    init(_ result: DappApprovalResult) {
        self.result = result
    }

    func approve(_ request: DappApprovalRequest) async -> DappApprovalResult {
        requests.append(request)
        return result
    }
}

private struct AptosDappFixture {
    static let chainId: UInt8 = 2
    static let origin = "https://dapp.example"

    let provider: AptosDappProvider
    let session: DappSession
    let signingService: DappSigningService
    let account: ReefrWallet.Account
    let signer: AptosPKeySigner

    static func make(curve: Curve = .ed25519) async throws -> AptosDappFixture {
        let databaseService = try makeDatabaseService()
        let transactionService = TransactionService(databaseService: databaseService)
        let keyStore = try await makeLocalKeyStore(databaseService: databaseService, name: "Aptos Dapp Key Store")
        let account = try await AccountService(databaseService: databaseService)
            .makeAccount(.aptos(.testnet), keyStore: keyStore, signatureScheme: curve)

        let session = DappSession(origin: origin)
        await session.setActiveAccount(account)

        let signer = try #require(try await transactionService.makeSigner(for: account) as? AptosPKeySigner)

        return AptosDappFixture(
            provider: AptosDappProvider(
                clientProvider: BlockchainClientProvider(),
                transactionService: transactionService,
                chainId: { _ in chainId }
            ),
            session: session,
            signingService: DappSigningService(transactionService: transactionService),
            account: account,
            signer: signer
        )
    }

    func call(
        _ method: String,
        _ params: JSONValue = .object([:]),
        approver: RecordingApprover
    ) async throws -> JSONValue {
        let context = DappRequestContext(
            origin: Self.origin,
            session: session,
            approving: approver,
            signingService: signingService
        )

        return try await provider.handle(method: method, params: params, context: context)
    }

    func connect() async throws {
        _ = try await call("connect", approver: RecordingApprover(.approved))
    }

    func rawTransaction(sender: AptosAddress? = nil, chainId: UInt8 = chainId) throws -> Data {
        AptosRawTransaction(
            sender: try sender ?? AptosAddress(string: account.address),
            sequenceNumber: 0,
            payload: .aptTransfer(to: try AptosAddress(string: "0x1"), amount: 1),
            maxGasAmount: 2_000,
            gasUnitPrice: 100,
            expirationTimestampSecs: 2_000_000_000,
            chainId: chainId
        ).bcs
    }

    var accountParams: JSONValue {
        .object(["address": .string(account.address)])
    }
}

private func expectDappError(
    _ matches: (DappError) -> Bool,
    _ body: () async throws -> Void,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    do {
        try await body()
        Issue.record("expected a DappError", sourceLocation: sourceLocation)
    } catch let error as DappError {
        #expect(matches(error), "unexpected \(error)", sourceLocation: sourceLocation)
    } catch {
        Issue.record("unexpected \(error)", sourceLocation: sourceLocation)
    }
}

struct AptosDappProviderTests {
    @Test func connectPromptsOnceAndReportsTheAccount() async throws {
        let fixture = try await AptosDappFixture.make()
        let approver = RecordingApprover(.approved)

        let first = try await fixture.call("connect", approver: approver)
        _ = try await fixture.call("connect", approver: approver)

        #expect(await approver.requests.count == 1)
        #expect(first["account"]?["addressString"]?.stringValue == fixture.account.address)
        let publicKeyBcs = try fixture.signer.publicKeyBcs().base64EncodedString()
        #expect(first["account"]?["publicKeyBcs"]?.stringValue == publicKeyBcs)
        #expect(first["network"]?["chainId"]?.numberValue == 2)
        #expect(first["network"]?["name"]?.stringValue == "testnet")
    }

    @Test func rejectedConnectSurfacesAsUserRejected() async throws {
        let fixture = try await AptosDappFixture.make()

        await expectDappError({ if case .userRejected = $0 { true } else { false } }, {
            _ = try await fixture.call("connect", approver: RecordingApprover(.rejected))
        })

        #expect(fixture.provider.wireError(.userRejected)["code"]?.numberValue == 4001)
    }

    @Test func accountIsNullUntilConnected() async throws {
        let fixture = try await AptosDappFixture.make()
        #expect(try await fixture.call("account", approver: RecordingApprover(.approved))["account"] == .null)
    }

    @Test(.serialized, arguments: [Curve.ed25519, .secp256k1])
    func signTransactionReturnsTheAccountAuthenticator(curve: Curve) async throws {
        let fixture = try await AptosDappFixture.make(curve: curve)
        let connected = try await fixture.call("connect", approver: RecordingApprover(.approved))
        let publicKey = connected["account"]?["publicKey"]?.stringValue.flatMap { Data(base64Encoded: $0) }
        #expect(publicKey?.count == (curve == .ed25519 ? 32 : 65))
        let approver = RecordingApprover(.approved)
        let bytes = try fixture.rawTransaction()

        let result = try await fixture.call(
            "signTransaction",
            .object(["rawTransaction": .string(bytes.base64EncodedString()), "account": fixture.accountParams]),
            approver: approver
        )

        let expected = try await fixture.signer.signAccountAuthenticator(transaction: bytes)
        #expect(result["authenticator"]?.stringValue == expected.base64EncodedString())
        #expect(await approver.requests.count == 1)
    }

    @Test func signTransactionRejectsAnotherSenderBeforePrompting() async throws {
        let fixture = try await AptosDappFixture.make()
        try await fixture.connect()
        let approver = RecordingApprover(.approved)
        let bytes = try fixture.rawTransaction(sender: AptosAddress(string: "0x" + String(repeating: "cd", count: 32)))

        await expectDappError({ if case .invalidParams = $0 { true } else { false } }, {
            _ = try await fixture.call(
                "signTransaction",
                .object(["rawTransaction": .string(bytes.base64EncodedString()), "account": fixture.accountParams]),
                approver: approver
            )
        })

        #expect(await approver.requests.isEmpty)
    }

    @Test func signTransactionRejectsAnotherChainBeforePrompting() async throws {
        let fixture = try await AptosDappFixture.make()
        try await fixture.connect()
        let approver = RecordingApprover(.approved)
        let bytes = try fixture.rawTransaction(chainId: 1)

        await expectDappError({ if case .chainNotFound = $0 { true } else { false } }, {
            _ = try await fixture.call(
                "signTransaction",
                .object(["rawTransaction": .string(bytes.base64EncodedString()), "account": fixture.accountParams]),
                approver: approver
            )
        })

        #expect(await approver.requests.isEmpty)
    }

    @Test func signTransactionRejectsUndecodableBytes() async throws {
        let fixture = try await AptosDappFixture.make()
        try await fixture.connect()
        let bytes = try fixture.rawTransaction() + Data([0])

        await expectDappError({ if case .invalidParams = $0 { true } else { false } }, {
            _ = try await fixture.call(
                "signTransaction",
                .object(["rawTransaction": .string(bytes.base64EncodedString()), "account": fixture.accountParams]),
                approver: RecordingApprover(.approved)
            )
        })
    }

    @Test func signingRequiresAConnectedOrigin() async throws {
        let fixture = try await AptosDappFixture.make()
        let bytes = try fixture.rawTransaction()

        await expectDappError({ if case .unauthorized = $0 { true } else { false } }, {
            _ = try await fixture.call(
                "signTransaction",
                .object(["rawTransaction": .string(bytes.base64EncodedString()), "account": fixture.accountParams]),
                approver: RecordingApprover(.approved)
            )
        })
    }

    @Test func signMessageSignsTheAssembledAip62Message() async throws {
        let fixture = try await AptosDappFixture.make()
        try await fixture.connect()
        let approver = RecordingApprover(.approved)

        let result = try await fixture.call(
            "signMessage",
            .object([
                "message": .string("hello"),
                "nonce": .string("7"),
                "address": .bool(true),
                "application": .bool(true),
                "chainId": .bool(true),
                "account": fixture.accountParams
            ]),
            approver: approver
        )

        let expectedMessage = """
        APTOS
        address: \(fixture.account.address)
        application: \(AptosDappFixture.origin)
        chainId: 2
        message: hello
        nonce: 7
        """
        #expect(result["fullMessage"]?.stringValue == expectedMessage)

        let expected = try await fixture.signer.sign(message: .aptosMessage(Data(expectedMessage.utf8)))
        #expect(result["signature"]?.stringValue == expected.base64EncodedString())

        guard case let .signMessage(_, _, _, .aptosMessage(previewed)) = await approver.requests.first else {
            Issue.record("expected an Aptos message approval")
            return
        }

        #expect(previewed == expectedMessage)
    }
}
