// Regression test for providers/sui.js's `change` listener: native sends
// an explicit `{accounts: []}` payload when the origin isn't permitted
// (or no account is selected) and a bare `null` payload when something
// changed for an *already permitted* origin (see SuiDappProvider.
// sessionDidChange). The listener used to ignore the payload entirely
// and always refetch via `connect`, which would surface an approval
// prompt the dapp never asked for — e.g. just from switching the
// browser's Sui account picker on an origin that was never connected.

import Foundation
import JavaScriptCore
import Testing
@testable import ReefrWallet

struct SuiWalletStandardProviderScriptTests {
    private func makeHarness() throws -> DappWalletStandardJSHarness {
        try DappWalletStandardJSHarness(
            providerResourceNames: ["vendor/sui-sdk.js", "providers/sui.js"]
        )
    }

    private func jsString(_ value: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        return String(data: data, encoding: .utf8) ?? "\"\""
    }

    /// Stages `window.__testInput` as a `SuiSignTransactionInput`-shaped
    /// object whose `transaction.toJSON()` resolves to `transactionJSON`
    /// — `sui.js`'s own `buildTransactionBytes` calls that, then builds
    /// it with the bundled SDK, exactly as it would a real dapp's
    /// `Transaction`.
    private func stageSignInput(
        _ harness: DappWalletStandardJSHarness, transactionJSON: String, sender: String
    ) throws {
        // swiftlint:disable all
        try harness.run("""
        window.__testInput = {
            transaction: { toJSON: function () { return Promise.resolve(\(try jsString(transactionJSON))); } },
            account: { address: \(try jsString(sender)) },
            chain: 'sui:testnet',
        };
        """)
        // swiftlint:enable all
    }

    @Test
    func changeEventWithExplicitEmptyAccountsDoesNotCallNativeConnect() throws {
        let harness = try makeHarness()
        let wallet = try #require(harness.registeredWallet)

        harness.handleRequest = { _, _, _ in
            Issue.record("native should not be called when the change payload already carries an empty account list")
            return .failure(.object(["message": .string("should not be called")]))
        }

        try harness.emit(namespace: "sui", event: "change", payload: .object(["accounts": .array([])]))

        #expect(harness.recordedRequests.isEmpty)
        #expect(wallet.objectForKeyedSubscript("accounts").toArray()?.isEmpty == true)
    }

    @Test
    func changeEventWithNullPayloadRefetchesViaConnect() throws {
        let harness = try makeHarness()
        let wallet = try #require(harness.registeredWallet)

        harness.handleRequest = { namespace, method, _ in
            #expect(namespace == "sui")
            #expect(method == "connect")
            return .success(.object([
                "accounts": .array([
                    .object([
                        "address": .string("0xabc"),
                        "publicKey": .string(Data(repeating: 0x01, count: 32).base64EncodedString()),
                        "chain": .string("sui:testnet")
                    ])
                ])
            ]))
        }

        try harness.emit(namespace: "sui", event: "change", payload: .null)

        #expect(harness.recordedRequests.count == 1)
        #expect(wallet.objectForKeyedSubscript("accounts").toArray()?.count == 1)
    }

    /// Regression test for the P1 finding this file's history traces
    /// back to: `signTransaction` used to forward `toJSON()`'s result
    /// (a JSON string) as `transactionBytes` directly, which
    /// `SuiDappProvider` can never base64-decode as BCS. This asserts
    /// the native `signTransaction` call actually receives real BCS
    /// bytes — byte-exact against the real SDK's own `build()` output
    /// (see TestVectors/sui-dapp-transactions.json).
    @Test
    func signTransactionSendsRealBcsBytesToNative() throws {
        let vector = TransactionVectorFile.load().vectors.first { $0.name == "fully-resolved-transfer" }!
        let harness = try makeHarness()
        _ = try #require(harness.registeredWallet)
        try stageSignInput(harness, transactionJSON: vector.transactionJSON, sender: vector.sender)

        harness.handleRequest = { namespace, method, params in
            #expect(namespace == "sui")
            #expect(method == "signTransaction")
            #expect(params["transactionBytes"]?.stringValue == vector.expectedBytesBase64)
            return .success(.object(["bytes": .string(vector.expectedBytesBase64), "signature": .string("c2ln")]))
        }

        let signExpression = "__capturedWallet.features['sui:signTransaction'].signTransaction(window.__testInput)"
        let result = try harness.invoke(signExpression)
        #expect(result["bytes"]?.stringValue == vector.expectedBytesBase64)
        #expect(result["signature"]?.stringValue == "c2ln")
    }

    /// Same regression, for `signAndExecuteTransaction` — and against a
    /// vector that needs real chain lookups (`getMoveFunction`/
    /// `getObjects`) to resolve, not just the trivial zero-lookup case
    /// `signTransaction`'s own test above covers.
    @Test
    func signAndExecuteTransactionSendsRealBcsBytesToNative() throws {
        let vector = TransactionVectorFile.load().vectors.first { $0.name == "movecall-shared-object-unresolved-pure" }!
        let harness = try makeHarness()
        _ = try #require(harness.registeredWallet)
        try stageSignInput(harness, transactionJSON: vector.transactionJSON, sender: vector.sender)

        harness.handleRequest = { namespace, method, params in
            #expect(namespace == "sui")
            if let response = vector.nativeResponses[method] {
                return .success(response)
            }
            #expect(method == "signAndExecuteTransaction")
            #expect(params["transactionBytes"]?.stringValue == vector.expectedBytesBase64)
            return .success(.object([
                "bytes": .string(vector.expectedBytesBase64),
                "signature": .string("c2ln"),
                "digest": .string("ZGlnZXN0"),
                "effects": .string("ZWZmZWN0cw==")
            ]))
        }

        let result = try harness.invoke(
            "__capturedWallet.features['sui:signAndExecuteTransaction'].signAndExecuteTransaction(window.__testInput)"
        )
        #expect(result["bytes"]?.stringValue == vector.expectedBytesBase64)
        #expect(result["digest"]?.stringValue == "ZGlnZXN0")
    }
}
