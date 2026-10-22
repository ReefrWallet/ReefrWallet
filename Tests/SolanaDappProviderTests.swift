// Tests for SolanaDappProvider, mirroring SuiDappProviderTests.swift's
// structure: `signTransaction`'s parse/authorize/sign path is pure local
// cryptography (no RPC), so hand-built legacy transactions (real signer
// addresses, fabricated blockhash/co-signer bytes) exercise it fully
// offline, including the "required signer, not fee payer" sponsored-
// transaction invariant. `signAndSendTransaction`'s broadcast step
// (`SolanaRPCClient.sendTransaction`) genuinely needs a live/stubbed RPC
// node and isn't covered here — that behavior (including "the returned
// signature is whatever the RPC reports, not necessarily the signer's
// own") is covered directly against WalletKit's `SolanaRPCClient` in
// WalletKit/Tests/Blockchains/Solana/SolanaSendTransactionOptionsTests.swift.
// Only `signAndSendTransaction`'s pre-approval option validation (which
// never touches the network) is covered here.

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

/// Like `StubApproving`, but counts calls — used to assert that
/// `connect(onlyIfTrusted: true)` never prompts.
private actor CountingApproving: DappApproving {
    let result: DappApprovalResult
    private(set) var callCount = 0

    init(result: DappApprovalResult) {
        self.result = result
    }

    func approve(_ request: DappApprovalRequest) async -> DappApprovalResult {
        callCount += 1
        return result
    }
}

struct SolanaDappProviderTests {
    @Test
    func connectRequiresApprovalThenGrantsPermission() async throws {
        let fixture = try await SolanaDappProviderFixture.make()
        let context = fixture.context(approving: StubApproving(result: .approved))

        #expect(await fixture.session.isPermitted(.solana) == false)

        let result = try await fixture.provider.handle(method: "connect", params: .object([:]), context: context)

        #expect(await fixture.session.isPermitted(.solana))
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
        #expect(chain == "solana:devnet")
    }

    @Test
    func connectRejectionThrowsUserRejectedWithNoNumericWireCode() async throws {
        let fixture = try await SolanaDappProviderFixture.make()
        let context = fixture.context(approving: StubApproving(result: .rejected))

        do {
            _ = try await fixture.provider.handle(method: "connect", params: .object([:]), context: context)
            Issue.record("expected connect to throw")
        } catch {
            let wireError = fixture.provider.wireError(error)
            #expect(wireError["code"] == nil)
            #expect(wireError["message"] != nil)
        }
        #expect(await fixture.session.isPermitted(.solana) == false)
    }

    @Test
    func connectWithOnlyIfTrustedRejectsSilentlyWithoutPromptingWhenNotPermitted() async throws {
        let fixture = try await SolanaDappProviderFixture.make()
        let approving = CountingApproving(result: .approved)
        let context = fixture.context(approving: approving)

        do {
            _ = try await fixture.provider.handle(
                method: "connect", params: .object(["onlyIfTrusted": .bool(true)]), context: context
            )

            Issue.record("expected connect(onlyIfTrusted: true) to reject when not yet permitted")
        } catch DappError.unauthorized {
            // Expected.
        }

        #expect(await approving.callCount == 0)
        #expect(await fixture.session.isPermitted(.solana) == false)
    }

    @Test
    func connectWithOnlyIfTrustedSucceedsSilentlyWhenAlreadyPermitted() async throws {
        let fixture = try await SolanaDappProviderFixture.make()
        let approving = CountingApproving(result: .approved)
        let context = fixture.context(approving: approving)

        _ = try await fixture.provider.handle(method: "connect", params: .object([:]), context: context)
        #expect(await fixture.session.isPermitted(.solana))
        #expect(await approving.callCount == 1)

        let result = try await fixture.provider.handle(
            method: "connect",
            params: .object(["onlyIfTrusted": .bool(true)]),
            context: context
        )
        #expect(result["accounts"]?.arrayValue?.count == 1)
        #expect(await approving.callCount == 1) // no additional prompt
    }

    /// Regression coverage for namespace-wide permission revocation —
    /// mirrors SuiDappProviderTests' identical test for the shared
    /// `DappSession` behavior.
    @Test
    func disconnectRevokesPermissionForEveryAccountNotJustTheCurrentlySelectedOne() async throws {
        let fixture = try await SolanaDappProviderFixture.make()
        let accountService = AccountService(databaseService: fixture.databaseService)
        let accountB = try await accountService.makeAccount(.solana(.devnet), keyStore: fixture.keyStore)
        let context = fixture.context(approving: StubApproving(result: .approved))

        _ = try await fixture.provider.handle(method: "connect", params: .object([:]), context: context)
        #expect(await fixture.session.isPermitted(.solana))

        await fixture.session.setActiveAccount(accountB)
        #expect(await fixture.session.isPermitted(.solana)) // carried forward

        _ = try await fixture.provider.handle(method: "disconnect", params: .object([:]), context: context)
        #expect(await fixture.session.isPermitted(.solana) == false)

        await fixture.session.setActiveAccount(fixture.account)
        #expect(await fixture.session.isPermitted(.solana) == false)
    }

    @Test
    func requestsWithADifferentlyCasedAddressAreRejectedBase58IsCaseSensitive() async throws {
        let (fixture, context) = try await connectedFixture()

        guard let flippedIndex = fixture.account.address.firstIndex(where: { $0.isLetter }) else {
            Issue.record("expected the test account's address to contain a letter")
            return
        }

        var flipped = fixture.account.address
        let original = flipped[flippedIndex]
        let swapped = original.isLowercase ? Character(original.uppercased()) : Character(original.lowercased())
        flipped.replaceSubrange(flippedIndex...flippedIndex, with: String(swapped))
        #expect(flipped != fixture.account.address)

        let params = JSONValue.object([
            "message": .string(Data("hello".utf8).base64EncodedString()),
            "account": .object(["address": .string(flipped)])
        ])

        let error = await #expect(throws: DappError.self) {
            try await fixture.provider.handle(method: "signMessage", params: params, context: context)
        }
        guard case .unauthorized = error else {
            Issue.record("expected unauthorized, got \(String(describing: error))")
            return
        }
    }

    @Test
    func signMessageMatchesAnIndependentlyDerivedSigner() async throws {
        let (fixture, context) = try await connectedFixture()

        let message = Data("Example solana:signMessage message".utf8)
        let params = JSONValue.object([
            "message": .string(message.base64EncodedString()),
            "account": .object(["address": .string(fixture.account.address)])
        ])

        let result = try await fixture.provider.handle(method: "signMessage", params: params, context: context)
        guard
            let signedMessageBase64 = result["signedMessage"]?.stringValue,
            let signatureBase64 = result["signature"]?.stringValue,
            let signature = Data(base64Encoded: signatureBase64)
        else {
            Issue.record("expected {signedMessage, signature}, got \(result)")
            return
        }
        #expect(signedMessageBase64 == message.base64EncodedString())

        let independentSigner = try fixture.makeIndependentSigner()
        let expectedSignature = try await independentSigner.sign(message: .solanaMessage(message))
        #expect(signature == expectedSignature)
    }

    @Test
    func signMessageRejectsRawLegacyTransactionMessageBytes() async throws {
        let (fixture, context) = try await connectedFixture()
        let accountAddress = try fixture.accountAddress
        let messageBytes = fixture.legacyMessageBytes(staticAccountKeys: [accountAddress], numRequiredSignatures: 1)

        try await expectSignMessageRejects(messageBytes, fixture: fixture, context: context)
    }

    @Test
    func signMessageRejectsRawV0TransactionMessageBytes() async throws {
        let (fixture, context) = try await connectedFixture()
        let accountAddress = try fixture.accountAddress
        let messageBytes = fixture.v0MessageBytes(staticAccountKeys: [accountAddress], numRequiredSignatures: 1)

        try await expectSignMessageRejects(messageBytes, fixture: fixture, context: context)
    }

    @Test
    func signMessageRejectsACompleteLegacyWireTransaction() async throws {
        let (fixture, context) = try await connectedFixture()
        let accountAddress = try fixture.accountAddress
        let messageBytes = fixture.legacyMessageBytes(staticAccountKeys: [accountAddress], numRequiredSignatures: 1)
        let transactionBytes = fixture.wrapTransaction(
            messageBytes: messageBytes,
            signatures: [Data(repeating: 0, count: 64)]
        )

        try await expectSignMessageRejects(transactionBytes, fixture: fixture, context: context)
    }

    @Test
    func signMessageRejectsACompleteV0WireTransaction() async throws {
        let (fixture, context) = try await connectedFixture()
        let accountAddress = try fixture.accountAddress
        let messageBytes = fixture.v0MessageBytes(staticAccountKeys: [accountAddress], numRequiredSignatures: 1)
        let transactionBytes = fixture.wrapTransaction(
            messageBytes: messageBytes,
            signatures: [Data(repeating: 0, count: 64)]
        )

        try await expectSignMessageRejects(transactionBytes, fixture: fixture, context: context)
    }

    private func connectedFixture() async throws -> (fixture: SolanaDappProviderFixture, context: DappRequestContext) {
        let fixture = try await SolanaDappProviderFixture.make()
        let context = fixture.context(approving: StubApproving(result: .approved))
        _ = try await fixture.provider.handle(method: "connect", params: .object([:]), context: context)
        return (fixture, context)
    }

    private func expectSignMessageRejects(
        _ bytes: Data, fixture: SolanaDappProviderFixture, context: DappRequestContext
    ) async throws {
        let params = JSONValue.object([
            "message": .string(bytes.base64EncodedString()),
            "account": .object(["address": .string(fixture.account.address)])
        ])
        do {
            _ = try await fixture.provider.handle(method: "signMessage", params: params, context: context)
            Issue.record("expected signMessage to reject transaction-shaped bytes")
        } catch DappError.invalidParams(_) {
            // Expected.
        }
    }

    @Test
    func signTransactionInSignerSlotZeroMatchesAnIndependentlyDerivedSignature() async throws {
        let (fixture, context) = try await connectedFixture()
        let accountAddress = try fixture.accountAddress
        let messageBytes = fixture.legacyMessageBytes(staticAccountKeys: [accountAddress], numRequiredSignatures: 1)
        let transactionBytes = fixture.wrapTransaction(
            messageBytes: messageBytes,
            signatures: [Data(repeating: 0, count: 64)]
        )

        let params = JSONValue.object([
            "transaction": .string(transactionBytes.base64EncodedString()),
            "account": .object(["address": .string(fixture.account.address)])
        ])
        let result = try await fixture.provider.handle(method: "signTransaction", params: params, context: context)
        guard
            let signedBase64 = result["signedTransaction"]?.stringValue,
            let signedBytes = Data(base64Encoded: signedBase64)
        else {
            Issue.record("expected {signedTransaction}, got \(result)")
            return
        }

        let signed = try SolanaWireTransaction(parsing: signedBytes)
        let independentSigner = try fixture.makeIndependentSigner()
        let expectedSignature = try await independentSigner.sign(
            transaction: SolanaUnsignedTransaction(message: messageBytes).encoded()
        )
        #expect(signed.signatures == [expectedSignature])
    }

    @Test
    func signTransactionInASponsoredNonZeroSlotPreservesTheFeePayerSignature() async throws {
        let (fixture, context) = try await connectedFixture()
        let accountAddress = try fixture.accountAddress
        let feePayer = try SolanaAddress(rawBytes: Data(repeating: 0x55, count: 32))
        let feePayerSignature = Data(repeating: 0x77, count: 64)

        // `account` occupies required-signer slot 1, not slot 0 (the fee
        // payer) — a sponsored transaction. `feePayerSignature` stands in
        // for a signature some other party already produced.
        let messageBytes = fixture.legacyMessageBytes(
            staticAccountKeys: [feePayer, accountAddress], numRequiredSignatures: 2
        )

        let transactionBytes = fixture.wrapTransaction(
            messageBytes: messageBytes, signatures: [feePayerSignature, Data(repeating: 0, count: 64)]
        )

        let params = JSONValue.object([
            "transaction": .string(transactionBytes.base64EncodedString()),
            "account": .object(["address": .string(fixture.account.address)])
        ])
        let result = try await fixture.provider.handle(method: "signTransaction", params: params, context: context)
        guard
            let signedBase64 = result["signedTransaction"]?.stringValue,
            let signedBytes = Data(base64Encoded: signedBase64)
        else {
            Issue.record("expected {signedTransaction}, got \(result)")
            return
        }

        let signed = try SolanaWireTransaction(parsing: signedBytes)
        let independentSigner = try fixture.makeIndependentSigner()
        let expectedSignature = try await independentSigner.sign(
            transaction: SolanaUnsignedTransaction(message: messageBytes).encoded()
        )
        #expect(signed.signatures[0] == feePayerSignature) // preserved, untouched
        #expect(signed.signatures[1] == expectedSignature)
    }

    @Test
    func signTransactionRejectsWhenTheAccountIsNotARequiredSigner() async throws {
        let (fixture, context) = try await connectedFixture()
        let accountAddress = try fixture.accountAddress
        let otherSigner = try SolanaAddress(rawBytes: Data(repeating: 0x33, count: 32))
        // header: 1 required signer (otherSigner), 0 readonly-signed, 1
        // readonly-unsigned (account is present but not a signer).
        let messageBytes = fixture.legacyMessageBytes(
            staticAccountKeys: [otherSigner, accountAddress],
            numRequiredSignatures: 1, numReadonlyUnsignedAccounts: 1
        )

        let transactionBytes = fixture.wrapTransaction(
            messageBytes: messageBytes,
            signatures: [Data(repeating: 0, count: 64)]
        )

        let params = JSONValue.object([
            "transaction": .string(transactionBytes.base64EncodedString()),
            "account": .object(["address": .string(fixture.account.address)])
        ])

        do {
            _ = try await fixture.provider.handle(method: "signTransaction", params: params, context: context)
            Issue.record("expected signTransaction to reject a non-required-signer account")
        } catch DappError.invalidParams(_) {
            // Expected.
        }
    }

    @Test
    func signTransactionRejectsMalformedWireBytes() async throws {
        let (fixture, context) = try await connectedFixture()

        let params = JSONValue.object([
            "transaction": .string(Data([0xFF, 0xFF, 0xFF]).base64EncodedString()),
            "account": .object(["address": .string(fixture.account.address)])
        ])

        do {
            _ = try await fixture.provider.handle(method: "signTransaction", params: params, context: context)
            Issue.record("expected signTransaction to reject malformed wire bytes")
        } catch DappError.invalidParams(_) {
            // Expected.
        }
    }

    @Test
    func signTransactionRejectsAChainMismatch() async throws {
        let (fixture, context) = try await connectedFixture() // account is on .devnet
        let accountAddress = try fixture.accountAddress
        let messageBytes = fixture.legacyMessageBytes(staticAccountKeys: [accountAddress], numRequiredSignatures: 1)
        let transactionBytes = fixture.wrapTransaction(
            messageBytes: messageBytes,
            signatures: [Data(repeating: 0, count: 64)]
        )

        let params = JSONValue.object([
            "transaction": .string(transactionBytes.base64EncodedString()),
            "account": .object(["address": .string(fixture.account.address)]),
            "chain": .string("solana:mainnet")
        ])

        do {
            _ = try await fixture.provider.handle(method: "signTransaction", params: params, context: context)
            Issue.record("expected signTransaction to reject a chain mismatch")
        } catch DappError.chainNotFound {
            // Expected.
        }
    }

    @Test
    func unauthorizedAccountIsRejectedBeforeParsing() async throws {
        let fixture = try await SolanaDappProviderFixture.make()
        let context = fixture.context(approving: StubApproving(result: .approved))
        // Deliberately not connected.

        let params = JSONValue.object([
            "transaction": .string(Data([0xFF]).base64EncodedString()),
            "account": .object(["address": .string(fixture.account.address)])
        ])

        do {
            _ = try await fixture.provider.handle(method: "signTransaction", params: params, context: context)
            Issue.record("expected signTransaction to reject an unauthorized account")
        } catch DappError.unauthorized {
            // Expected.
        }
    }

    // MARK: - signAndSendTransaction option validation

    @Test
    func signAndSendTransactionRejectsAnUnsupportedCommitment() async throws {
        try await expectSignAndSendRejectsOptions(.object(["commitment": .string("not-a-commitment")]))
    }

    @Test
    func signAndSendTransactionRejectsANonIntegralMaxRetries() async throws {
        try await expectSignAndSendRejectsOptions(.object(["maxRetries": .number(1.5)]))
    }

    @Test
    func signAndSendTransactionRejectsANegativeMinContextSlot() async throws {
        try await expectSignAndSendRejectsOptions(.object(["minContextSlot": .number(-1)]))
    }

    @Test
    func signAndSendTransactionRejectsANonBooleanSkipPreflight() async throws {
        try await expectSignAndSendRejectsOptions(.object(["skipPreflight": .string("true")]))
    }

    @Test
    func signAndSendTransactionRejectsANonObjectOptions() async throws {
        try await expectSignAndSendRejectsOptions(.string("nope"))
    }

    /// Option validation happens before `validateAndSign` (and therefore
    /// before any network call), so these are fully offline — the
    /// `transaction`/`account` fields don't even need to parse.
    private func expectSignAndSendRejectsOptions(_ options: JSONValue) async throws {
        let (fixture, context) = try await connectedFixture()

        let params = JSONValue.object([
            "transaction": .string(Data([0xFF]).base64EncodedString()),
            "account": .object(["address": .string(fixture.account.address)]),
            "options": options
        ])

        do {
            _ = try await fixture.provider.handle(method: "signAndSendTransaction", params: params, context: context)
            Issue.record("expected signAndSendTransaction to reject these options")
        } catch DappError.invalidParams(_) {
            // Expected.
        }
    }
}
