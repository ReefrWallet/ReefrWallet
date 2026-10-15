// Tests for Resources/Browser/providers/solana.js itself, run against
// the real script via DappWalletStandardJSHarness (Tests/Support) — not
// just the native SolanaDappProvider it calls into. DappBridgeTests.swift
// deliberately never runs the JS side (WKScriptMessage has no public
// initializer), so without this, the script's own behavior — declared
// feature shapes, variadic input/output handling, Uint8Array<->base64
// conversion, option forwarding, and the native "change" event
// replacing `accounts` directly — would be entirely unverified.

import Foundation
import JavaScriptCore
import Testing
@testable import ReefrWallet

struct SolanaWalletStandardProviderScriptTests {
    private func makeHarness() throws -> DappWalletStandardJSHarness {
        try DappWalletStandardJSHarness(providerResourceNames: ["providers/solana.js"])
    }

    @Test
    func declaresTheExpectedChainsAndFeatureVersions() throws {
        let harness = try makeHarness()
        let wallet = try #require(harness.registeredWallet)

        let chains = wallet.objectForKeyedSubscript("chains").toArray() as? [String]
        #expect(chains == ["solana:mainnet", "solana:devnet", "solana:testnet"])

        let features = try #require(wallet.objectForKeyedSubscript("features"))

        #expect(
            features
                .objectForKeyedSubscript("standard:connect")
                .objectForKeyedSubscript("version")
                .toString() == "1.0.0"
        )

        #expect(
            features
                .objectForKeyedSubscript("standard:disconnect")
                .objectForKeyedSubscript("version")
                .toString() == "1.0.0"
        )

        #expect(
            features
                .objectForKeyedSubscript("standard:events")
                .objectForKeyedSubscript("version")
                .toString() == "1.0.0"
        )

        #expect(
            features
                .objectForKeyedSubscript("solana:signMessage")
                .objectForKeyedSubscript("version")
                .toString() == "1.1.0"
        )

        for featureName in ["solana:signTransaction", "solana:signAndSendTransaction"] {
            let feature = try #require(features.objectForKeyedSubscript(featureName))
            #expect(feature.objectForKeyedSubscript("version").toString() == "1.0.0")

            let supported = feature.objectForKeyedSubscript("supportedTransactionVersions").toArray()
            let supportedValue = JSONValue(any: supported as Any)
            #expect(supportedValue.arrayValue?.first?.stringValue == "legacy")
            #expect(supportedValue.arrayValue?.last?.numberValue == 0)
        }
    }

    @Test
    func signMessageProcessesVariadicInputsSequentiallyAndPreservesOutputOrder() throws {
        let harness = try makeHarness()
        _ = try #require(harness.registeredWallet)

        let firstMessage = Data("first message".utf8)
        let secondMessage = Data("second message".utf8)
        let firstMessageBase64 = firstMessage.base64EncodedString()
        let secondMessageBase64 = secondMessage.base64EncodedString()

        harness.handleRequest = { namespace, method, params in
            #expect(namespace == "solana")
            #expect(method == "signMessage")
            guard let messageBase64 = params["message"]?.stringValue else {
                return .failure(.object(["message": .string("missing message")]))
            }

            let signatureByte: UInt8 = messageBase64 == firstMessageBase64 ? 0x01 : 0x02
            let signature = Data(repeating: signatureByte, count: 64)
            return .success(.object([
                "signedMessage": .string(messageBase64),
                "signature": .string(signature.base64EncodedString())
            ]))
        }

        try harness.stageInput(
            name: "__input0",
            jsonObject: ["message": Array(firstMessage), "account": ["address": "AddressA"]],
            byteArrayFields: ["message"]
        )

        try harness.stageInput(
            name: "__input1",
            jsonObject: ["message": Array(secondMessage), "account": ["address": "AddressA"]],
            byteArrayFields: ["message"]
        )

        let result = try harness.invoke(
            "__capturedWallet.features['solana:signMessage'].signMessage(window.__input0, window.__input1)",
            resultTransform: """
            value.map(function (o) {
                return {
                    signedMessage: window.__reefrWalletStandard.bytesToBase64(o.signedMessage),
                    signature: window.__reefrWalletStandard.bytesToBase64(o.signature),
                };
            })
            """
        )

        // Sequential, in order: native saw message A before message B.
        let sentMessages = harness.recordedRequests.map(\.params).map { $0["message"]?.stringValue }
        #expect(sentMessages == [firstMessageBase64, secondMessageBase64])

        guard let outputs = result.arrayValue, outputs.count == 2 else {
            Issue.record("expected 2 outputs, got \(result)")
            return
        }
        #expect(outputs[0]["signedMessage"]?.stringValue == firstMessageBase64)
        #expect(outputs[0]["signature"]?.stringValue == Data(repeating: 0x01, count: 64).base64EncodedString())
        #expect(outputs[1]["signedMessage"]?.stringValue == secondMessageBase64)
        #expect(outputs[1]["signature"]?.stringValue == Data(repeating: 0x02, count: 64).base64EncodedString())
    }

    @Test
    func signTransactionConvertsUint8ArrayInputAndOutput() throws {
        let harness = try makeHarness()
        _ = try #require(harness.registeredWallet)

        let transactionBytes = Data([0x01, 0x02, 0x03])
        let signedBytes = Data([0xAA, 0xBB, 0xCC])

        harness.handleRequest = { namespace, method, params in
            #expect(namespace == "solana")
            #expect(method == "signTransaction")
            #expect(params["transaction"]?.stringValue == transactionBytes.base64EncodedString())
            #expect(params["account"]?["address"]?.stringValue == "AddressA")
            #expect(params["chain"]?.stringValue == "solana:devnet")
            return .success(.object(["signedTransaction": .string(signedBytes.base64EncodedString())]))
        }

        try harness.stageInput(
            name: "__input0",
            jsonObject: [
                "transaction": Array(transactionBytes), "account": ["address": "AddressA"], "chain": "solana:devnet"
            ],
            byteArrayFields: ["transaction"]
        )

        let result = try harness.invoke(
            "__capturedWallet.features['solana:signTransaction'].signTransaction(window.__input0)",
            resultTransform: """
            value.map(function (o) {
                return { signedTransaction: window.__reefrWalletStandard.bytesToBase64(o.signedTransaction) };
            })
            """
        )

        #expect(result.arrayValue?.count == 1)
        #expect(result.arrayValue?.first?["signedTransaction"]?.stringValue == signedBytes.base64EncodedString())
    }

    @Test
    func signAndSendTransactionForwardsEveryStandardOption() throws {
        let harness = try makeHarness()
        _ = try #require(harness.registeredWallet)

        var forwardedOptions: JSONValue?
        harness.handleRequest = { _, _, params in
            forwardedOptions = params["options"]
            return .success(.object(["signature": .string(Data(repeating: 0x01, count: 64).base64EncodedString())]))
        }

        try harness.stageInput(
            name: "__input0",
            jsonObject: [
                "transaction": [UInt8]([0x01]),
                "account": ["address": "AddressA"],
                "chain": "solana:devnet",
                "options": [
                    "commitment": "confirmed",
                    "maxRetries": 3,
                    "minContextSlot": 100,
                    "preflightCommitment": "processed",
                    "skipPreflight": true
                ] as [String: Any]
            ],
            byteArrayFields: ["transaction"]
        )

        try harness.invoke(
            "__capturedWallet.features['solana:signAndSendTransaction'].signAndSendTransaction(window.__input0)",
            resultTransform: """
            value.map(function (o) {
                return { signature: window.__reefrWalletStandard.bytesToBase64(o.signature) };
            })
            """
        )

        #expect(forwardedOptions?["commitment"]?.stringValue == "confirmed")
        #expect(forwardedOptions?["maxRetries"]?.numberValue == 3)
        #expect(forwardedOptions?["minContextSlot"]?.numberValue == 100)
        #expect(forwardedOptions?["preflightCommitment"]?.stringValue == "processed")
        #expect(forwardedOptions?["skipPreflight"]?.boolValue == true)
    }

    @Test
    func changeListenerReplacesAccountsFromTheNativeEventPayloadWithNoExtraRequest() throws {
        let harness = try makeHarness()
        _ = try #require(harness.registeredWallet)

        try harness.context.evaluateScriptOrThrow("""
        window.__changePayloads = [];
        __capturedWallet.features['standard:events'].on('change', function (payload) {
            window.__changePayloads.push({
                accountCount: payload.accounts.length,
                address: payload.accounts.length > 0 ? payload.accounts[0].address : null,
            });
        });
        """)

        let requestCountBeforeEmit = harness.recordedRequests.count

        try harness.emit(namespace: "solana", event: "change", payload: .object([
            "accounts": .array([
                .object([
                    "address": .string("AddressB"),
                    "publicKey": .string(Data(repeating: 0x09, count: 32).base64EncodedString()),
                    "chain": .string("solana:devnet")
                ])
            ])
        ]))

        // No async re-fetch — native's own "change" payload already
        // carries the full account list (unlike providers/sui.js).
        #expect(harness.recordedRequests.count == requestCountBeforeEmit)

        let payloads = JSONValue(any: harness.context.evaluateScript("window.__changePayloads")?.toObject() ?? NSNull())
        #expect(payloads.arrayValue?.count == 1)
        #expect(payloads.arrayValue?.first?["accountCount"]?.numberValue == 1)
        #expect(payloads.arrayValue?.first?["address"]?.stringValue == "AddressB")
    }
}

private extension JSContext {
    /// `evaluateScript` doesn't itself throw — `exceptionHandler` is
    /// fire-and-forget — so tests that don't go through
    /// `DappWalletStandardJSHarness.invoke`/`stageInput` (which do check)
    /// need their own explicit check for setup scripts.
    func evaluateScriptOrThrow(_ script: String) throws {
        var caught: String?
        let previous = exceptionHandler
        exceptionHandler = { context, exception in
            caught = exception?.toString()
            previous?(context, exception)
        }

        evaluateScript(script)
        exceptionHandler = previous
        if let caught {
            throw DappWalletStandardJSHarnessError(description: caught)
        }
    }
}
