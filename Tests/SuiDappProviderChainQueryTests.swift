// Tests for SuiDappProvider's chain-query lookup methods
// (getCoins/getObjects/getMoveFunction/getReferenceGasPrice/
// simulateTransaction) and the MoveCall approval path they exist to
// support — split out of SuiDappProviderTests.swift purely to keep
// that file under its line-count limit.

import Foundation
import Testing
import WalletKit
import WalletKitTesting
@testable import ReefrWallet

/// Answers every approval request immediately with a preset result —
/// same shape as `SuiDappProviderTests.swift`'s own (file-private)
/// copy; each test file in this target keeps one of these rather than
/// sharing a single internal type across files.
private struct StubApproving: DappApproving {
    let result: DappApprovalResult

    func approve(_ request: DappApprovalRequest) async -> DappApprovalResult {
        result
    }
}

struct SuiDappProviderChainQueryTests {
    /// The `get*`/`simulateTransaction` lookup methods `sui-transaction-
    /// builder.js` depends on must be gated exactly like signing is —
    /// an origin that never called `connect` gets nothing.
    @Test
    func chainLookupMethodsRequireAnAuthorizedOrigin() async throws {
        let fake = FakeSuiDappChainQuerying()
        let fixture = try await SuiDappProviderFixture.make(chainClient: fake)
        let context = fixture.context(approving: StubApproving(result: .approved))
        // Deliberately not connected.

        let account = JSONValue.object(["address": .string(fixture.account.address)])
        let calls: [(String, JSONValue)] = [
            ("getCoins", .object(["coinType": .string("0x2::sui::SUI"), "account": account])),
            ("getObjects", .object(["objectIds": .array([.string("0x6")]), "account": account])),
            (
                "getMoveFunction",
                .object([
                    "package": .string("0x2"), "module": .string("clock"),
                    "function": .string("timestamp_ms"), "account": account
                ])
            ),
            ("getReferenceGasPrice", .object(["account": account])),
            ("simulateTransaction", .object(["transactionBytes": .string(""), "account": account]))
        ]

        for (method, params) in calls {
            do {
                _ = try await fixture.provider.handle(method: method, params: params, context: context)
                Issue.record("expected \(method) to reject an unauthorized origin")
            } catch DappError.unauthorized {
                // Expected.
            }
        }
    }

    @Test
    func getCoinsIsScopedToTheSelectedAccount() async throws {
        let fake = FakeSuiDappChainQuerying()
        let coin = SuiCoinObject(
            reference: SuiObjectReference(
                objectId: Data(repeating: 0x33, count: 32), version: 5, digest: Data(repeating: 0x44, count: 32)
            ),
            balance: 42
        )

        fake.coinsByType["0x2::sui::SUI"] = [coin]

        let fixture = try await SuiDappProviderFixture.make(chainClient: fake)
        let context = fixture.context(approving: StubApproving(result: .approved))
        _ = try await fixture.provider.handle(method: "connect", params: .object([:]), context: context)

        let params = JSONValue.object([
            "coinType": .string("0x2::sui::SUI"),
            "account": .object(["address": .string(fixture.account.address)])
        ])
        let result = try await fixture.provider.handle(method: "getCoins", params: params, context: context)

        #expect(fake.ownedCoinsRequests.count == 1)
        let requestedAddress = fake.ownedCoinsRequests.first?.address.string
        #expect(requestedAddress?.caseInsensitiveCompare(fixture.account.address) == .orderedSame)
        guard let coins = result["coins"]?.arrayValue, coins.count == 1 else {
            Issue.record("expected {coins: [1 coin]}, got \(result)")
            return
        }
        #expect(coins[0]["balance"]?.stringValue == "42")
    }

    /// `simulateTransaction` shares `signTransaction`'s invariant: the
    /// bytes must decode and name the authorized account as sender
    /// before native ever simulates them — simulation isn't a reason
    /// to relax that.
    @Test
    func simulateTransactionRejectsAForeignSender() async throws {
        let fake = FakeSuiDappChainQuerying()
        let fixture = try await SuiDappProviderFixture.make(chainClient: fake)
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
            _ = try await fixture.provider.handle(method: "simulateTransaction", params: params, context: context)
            Issue.record("expected simulateTransaction to reject a sender mismatch")
        } catch DappError.invalidParams(_) {
            // Expected.
        }
    }

    /// Regression test for the decoder extension this provider now
    /// relies on: a `Command::MoveCall` transaction used to be rejected
    /// outright by `SuiTransactionDataDecoder` (fail-closed on an
    /// unrecognized command), so it could never reach approval. It must
    /// now decode, and the approval preview must name the called
    /// function.
    @Test
    func signTransactionWithMoveCallReachesApprovalNamingTheFunction() async throws {
        let fixture = try await SuiDappProviderFixture.make()
        let recordingApproving = RecordingApproving(result: .approved)
        let context = fixture.context(approving: recordingApproving)
        _ = try await fixture.provider.handle(method: "connect", params: .object([:]), context: context)

        let transactionBytes = try fixture.validMoveCallTransactionBytes()
        let params = JSONValue.object([
            "transactionBytes": .string(transactionBytes.base64EncodedString()),
            "account": .object(["address": .string(fixture.account.address)])
        ])

        let result = try await fixture.provider.handle(method: "signTransaction", params: params, context: context)
        #expect(result["signature"]?.stringValue != nil)

        guard
            case let .sendTransaction(_, _, _, preview) = recordingApproving.lastRequest,
            case let .sui(suiPreview) = preview
        else {
            let request = String(describing: recordingApproving.lastRequest)
            Issue.record("expected a sendTransaction(.sui) approval request, got \(request)")
            return
        }

        #expect(suiPreview.summary.moveCalls.count == 1)
        #expect(suiPreview.summary.moveCalls.first?.module == "clock")
        #expect(suiPreview.summary.moveCalls.first?.function == "timestamp_ms")

        // The approval screen itself must surface that call, not just the
        // decoder.
        let view = SuiTransactionPreviewView(preview: suiPreview)
        #expect(view.moveCallDescriptions.count == 1)
        let description = try #require(view.moveCallDescriptions.first)
        let package = try #require(suiPreview.summary.moveCalls.first?.package.string)
        #expect(description == "\(package)::clock::timestamp_ms")
    }
}
