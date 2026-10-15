// Tests for Resources/Browser/providers/solana-legacy.js — the Phantom-
// shaped `window.solana` direct-injection surface, run against the real
// script via DappWalletStandardJSHarness (Tests/Support), the same
// harness SolanaWalletStandardProviderScriptTests.swift uses for
// providers/solana.js. Covers the pieces that are specific to this
// script: identity, the single-account connect/disconnect/accountChanged
// event model, and — the real risk surface — duck-typing a legacy
// `Transaction`/`VersionedTransaction`-shaped object into the exact wire
// bytes native expects, then writing only this account's signature slot
// back into that same object.

import Foundation
import JavaScriptCore
import Testing
import WalletKit
@testable import ReefrWallet

struct SolanaLegacyProviderScriptTests {
    private func makeHarness() throws -> DappWalletStandardJSHarness {
        try DappWalletStandardJSHarness(providerResourceNames: ["providers/solana-legacy.js"])
    }

    /// Stubs a `connect` response and drives `window.solana.connect()`,
    /// leaving the script in a connected state for tests that need one.
    private func connect(_ harness: DappWalletStandardJSHarness, address: String, publicKey: Data) throws {
        harness.handleRequest = { _, method, _ in
            guard method == "connect" else {
                return .failure(.object(["message": .string("unexpected method during connect helper")]))
            }

            return .success(.object([
                "accounts": .array([
                    .object([
                        "address": .string(address),
                        "publicKey": .string(publicKey.base64EncodedString()),
                        "chain": .string("solana:devnet")
                    ])
                ])
            ]))
        }

        try harness.invoke("window.solana.connect()")
    }

    /// Builds the two-signature wire shapes shared by the legacy- and
    /// versioned-transaction tests: `expected` is what native should be
    /// asked to sign (our slot still zeroed), `signed` is what it hands
    /// back (our slot filled in).
    private func twoSignatureWire(
        messageBytes: Data, coSignerSignature: Data, ourSignature: Data
    ) -> (expected: Data, signed: Data) {
        var expected = Data([2])
        expected.append(coSignerSignature)
        expected.append(Data(repeating: 0, count: 64))
        expected.append(messageBytes)

        var signed = Data([2])
        signed.append(coSignerSignature)
        signed.append(ourSignature)
        signed.append(messageBytes)

        return (expected, signed)
    }

    private func stageByteInputs(
        _ harness: DappWalletStandardJSHarness, _ inputs: [(name: String, bytes: Data)]
    ) throws {
        for input in inputs {
            try harness.stageInput(
                name: input.name, jsonObject: ["bytes": Array(input.bytes)], byteArrayFields: ["bytes"]
            )
        }
    }

    // MARK: - Identity

    @Test
    func injectsWindowSolanaWithHonestIdentity() throws {
        let harness = try makeHarness()
        let solana = try #require(harness.context.evaluateScript("window.solana"))

        #expect(solana.objectForKeyedSubscript("isReefr").toBool() == true)
        #expect(solana.objectForKeyedSubscript("isPhantom").isUndefined)
        #expect(harness.context.evaluateScript("window.phantom")?.isUndefined ?? true)
    }

    // MARK: - Connect / disconnect / events

    @Test
    func connectAndDisconnectUpdateStateAndEmitEvents() throws {
        let harness = try makeHarness()
        let address = "AddressA"
        let publicKey = Data(repeating: 0x01, count: 32)

        // swiftlint:disable all
        try harness.run("""
        window.__events = [];
        window.solana.on('connect', function (pk) { window.__events.push({ type: 'connect', address: pk.toBase58() }); });
        window.solana.on('disconnect', function () { window.__events.push({ type: 'disconnect' }); });
        """)
        // swiftlint:enable all

        try connect(harness, address: address, publicKey: publicKey)
        #expect(harness.context.evaluateScript("window.solana.isConnected")?.toBool() == true)
        #expect(harness.context.evaluateScript("window.solana.publicKey.toBase58()")?.toString() == address)

        harness.handleRequest = { _, method, _ in
            #expect(method == "disconnect")
            return .success(.null)
        }

        try harness.invoke("window.solana.disconnect()")
        #expect(harness.context.evaluateScript("window.solana.isConnected")?.toBool() == false)
        #expect(harness.context.evaluateScript("window.solana.publicKey")?.isNull == true)

        let events = JSONValue(any: harness.context.evaluateScript("window.__events")?.toObject() ?? NSNull())
        #expect(events.arrayValue?.count == 2)
        #expect(events.arrayValue?[0]["type"]?.stringValue == "connect")
        #expect(events.arrayValue?[0]["address"]?.stringValue == address)
        #expect(events.arrayValue?[1]["type"]?.stringValue == "disconnect")
    }

    @Test
    func connectForwardsOnlyIfTrusted() throws {
        let harness = try makeHarness()
        harness.handleRequest = { _, method, _ in
            guard method == "connect" else {
                return .failure(.object(["message": .string("unexpected method")]))
            }

            return .success(.object([
                "accounts": .array([
                    .object([
                        "address": .string("AddressA"),
                        "publicKey": .string(Data(repeating: 0x01, count: 32).base64EncodedString()),
                        "chain": .string("solana:devnet")
                    ])
                ])
            ]))
        }

        try harness.invoke("window.solana.connect({ onlyIfTrusted: true })")

        #expect(harness.recordedRequests.last?.params["onlyIfTrusted"]?.boolValue == true)
    }

    @Test
    func nativeChangeEventTranslatesToConnectAccountChangedAndDisconnect() throws {
        let harness = try makeHarness()

        // swiftlint:disable all
        try harness.run("""
        window.__events = [];
        window.solana.on('connect', function (pk) { window.__events.push({ type: 'connect', address: pk.toBase58() }); });
        window.solana.on('accountChanged', function (pk) { window.__events.push({ type: 'accountChanged', address: pk ? pk.toBase58() : null }); });
        window.solana.on('disconnect', function () { window.__events.push({ type: 'disconnect' }); });
        """)
        // swiftlint:enable all

        func accountsPayload(_ address: String) -> JSONValue {
            .object(["accounts": .array([
                .object([
                    "address": .string(address),
                    "publicKey": .string(Data(repeating: 0x02, count: 32).base64EncodedString()),
                    "chain": .string("solana:devnet")
                ])
            ])])
        }

        try harness.emit(namespace: "solana", event: "change", payload: accountsPayload("AddressA"))
        try harness.emit(namespace: "solana", event: "change", payload: accountsPayload("AddressB"))
        try harness.emit(namespace: "solana", event: "change", payload: .object(["accounts": .array([])]))

        let events = JSONValue(any: harness.context.evaluateScript("window.__events")?.toObject() ?? NSNull())
        #expect(events.arrayValue?.count == 3)
        #expect(events.arrayValue?[0]["type"]?.stringValue == "connect")
        #expect(events.arrayValue?[0]["address"]?.stringValue == "AddressA")
        #expect(events.arrayValue?[1]["type"]?.stringValue == "accountChanged")
        #expect(events.arrayValue?[1]["address"]?.stringValue == "AddressB")
        #expect(events.arrayValue?[2]["type"]?.stringValue == "disconnect")
    }

    // MARK: - signMessage

    @Test
    func signMessageRoundTripsSignatureAndPublicKey() throws {
        let harness = try makeHarness()
        try connect(harness, address: "AddressA", publicKey: Data(repeating: 0x01, count: 32))

        let message = Data("hello".utf8)
        let signature = Data(repeating: 0x05, count: 64)

        harness.handleRequest = { namespace, method, params in
            #expect(namespace == "solana")
            #expect(method == "signMessage")
            #expect(params["message"]?.stringValue == message.base64EncodedString())
            #expect(params["account"]?["address"]?.stringValue == "AddressA")
            return .success(.object(["signature": .string(signature.base64EncodedString())]))
        }

        try harness.stageInput(name: "__message", jsonObject: ["bytes": Array(message)], byteArrayFields: ["bytes"])
        // swiftlint:disable all
        let result = try harness.invoke(
            "window.solana.signMessage(window.__message.bytes)",
            resultTransform: """
            {
                signature: window.__reefrWalletStandard.bytesToBase64(value.signature),
                address: value.publicKey.toBase58(),
            }
            """
        )
        // swiftlint:enable all

        #expect(result["signature"]?.stringValue == signature.base64EncodedString())
        #expect(result["address"]?.stringValue == "AddressA")
    }

    // MARK: - signTransaction duck-typing

    @Test
    func signTransactionWritesOnlyOurSlotOnALegacyTransactionShapedObject() throws {
        let harness = try makeHarness()
        try connect(harness, address: "AddressA", publicKey: Data(repeating: 0x01, count: 32))

        let messageBytes = Data([0x10, 0x20, 0x30])
        let coSignerSignature = Data(repeating: 0x07, count: 64)
        let ourSignature = Data(repeating: 0x09, count: 64)
        let (expectedWire, signedWire) = twoSignatureWire(
            messageBytes: messageBytes, coSignerSignature: coSignerSignature, ourSignature: ourSignature
        )

        harness.handleRequest = { _, method, params in
            #expect(method == "signTransaction")
            #expect(params["transaction"]?.stringValue == expectedWire.base64EncodedString())
            #expect(params["account"]?["address"]?.stringValue == "AddressA")
            return .success(.object(["signedTransaction": .string(signedWire.base64EncodedString())]))
        }

        try stageByteInputs(harness, [
            (name: "__messageBytes", bytes: messageBytes),
            (name: "__coSignerSig", bytes: coSignerSignature)
        ])

        // swiftlint:disable all
        try harness.run("""
        window.__legacyTx = {
            addSignatureCalls: [],
            signatures: [
                { publicKey: { toBase58: function () { return 'CoSigner'; } }, signature: window.__coSignerSig.bytes },
                { publicKey: { toBase58: function () { return 'AddressA'; } }, signature: null },
            ],
            serializeMessage: function () { return window.__messageBytes.bytes; },
            addSignature: function (publicKey, signature) {
                this.addSignatureCalls.push(publicKey.toBase58());
                for (var i = 0; i < this.signatures.length; i++) {
                    if (this.signatures[i].publicKey.toBase58() === publicKey.toBase58()) {
                        this.signatures[i].signature = signature;
                    }
                }
            },
        };
        """)

        let result = try harness.invoke(
            "window.solana.signTransaction(window.__legacyTx)",
            resultTransform: """
            {
                addSignatureCalls: window.__legacyTx.addSignatureCalls,
                coSignerSignature: window.__reefrWalletStandard.bytesToBase64(window.__legacyTx.signatures[0].signature),
                ourSignature: window.__reefrWalletStandard.bytesToBase64(window.__legacyTx.signatures[1].signature),
            }
            """
        )
        // swiftlint:enable all

        #expect(result["addSignatureCalls"]?.arrayValue == [.string("AddressA")])
        #expect(result["coSignerSignature"]?.stringValue == coSignerSignature.base64EncodedString()) // untouched
        #expect(result["ourSignature"]?.stringValue == ourSignature.base64EncodedString())
    }

    @Test
    func signTransactionWritesOnlyOurSlotOnAVersionedTransactionShapedObject() throws {
        let harness = try makeHarness()
        try connect(harness, address: "AddressA", publicKey: Data(repeating: 0x01, count: 32))

        let messageBytes = Data([0x11, 0x22])
        let coSignerSignature = Data(repeating: 0x03, count: 64)
        let ourSignature = Data(repeating: 0x04, count: 64)
        let (expectedWire, signedWire) = twoSignatureWire(
            messageBytes: messageBytes, coSignerSignature: coSignerSignature, ourSignature: ourSignature
        )

        harness.handleRequest = { _, method, params in
            #expect(method == "signTransaction")
            #expect(params["transaction"]?.stringValue == expectedWire.base64EncodedString())
            return .success(.object(["signedTransaction": .string(signedWire.base64EncodedString())]))
        }

        try stageByteInputs(harness, [
            (name: "__vMessageBytes", bytes: messageBytes),
            (name: "__vCoSignerSig", bytes: coSignerSignature),
            (name: "__vZero", bytes: Data(repeating: 0, count: 64))
        ])

        // swiftlint:disable all
        try harness.run("""
        window.__versionedTx = {
            signatures: [window.__vCoSignerSig.bytes, window.__vZero.bytes],
            message: {
                header: { numRequiredSignatures: 2 },
                staticAccountKeys: [
                    { toBase58: function () { return 'CoSigner'; } },
                    { toBase58: function () { return 'AddressA'; } },
                ],
                serialize: function () { return window.__vMessageBytes.bytes; },
            },
        };
        """)

        let result = try harness.invoke(
            "window.solana.signTransaction(window.__versionedTx)",
            resultTransform: """
            {
                coSignerSignature: window.__reefrWalletStandard.bytesToBase64(window.__versionedTx.signatures[0]),
                ourSignature: window.__reefrWalletStandard.bytesToBase64(window.__versionedTx.signatures[1]),
            }
            """
        )
        // swiftlint:enable all

        #expect(result["coSignerSignature"]?.stringValue == coSignerSignature.base64EncodedString()) // untouched
        #expect(result["ourSignature"]?.stringValue == ourSignature.base64EncodedString())
    }

    @Test
    func signTransactionRejectsAnUnsupportedObjectShapeWithoutAnyNativeRequest() throws {
        let harness = try makeHarness()
        try connect(harness, address: "AddressA", publicKey: Data(repeating: 0x01, count: 32))

        harness.handleRequest = { _, _, _ in
            Issue.record("native should not be called for an unsupported transaction object")
            return .failure(.object(["message": .string("should not be called")]))
        }

        #expect(throws: (any Swift.Error).self) {
            try harness.invoke("window.solana.signTransaction({ notATransaction: true })")
        }
    }

    @Test
    func signAllTransactionsProcessesSequentiallyAndPreservesOrder() throws {
        let harness = try makeHarness()
        try connect(harness, address: "AddressA", publicKey: Data(repeating: 0x01, count: 32))

        let messageA = Data([0xA1])
        let messageB = Data([0xB1])
        var expectedWireA = Data([1])
        expectedWireA.append(Data(repeating: 0, count: 64))
        expectedWireA.append(messageA)
        var expectedWireB = Data([1])
        expectedWireB.append(Data(repeating: 0, count: 64))
        expectedWireB.append(messageB)

        harness.handleRequest = { _, method, params in
            guard
                method == "signTransaction",
                let txBase64 = params["transaction"]?.stringValue,
                let inputBytes = Data(base64Encoded: txBase64)
            else {
                return .failure(.object(["message": .string("bad request")]))
            }

            var signed = inputBytes
            signed.replaceSubrange(1..<65, with: Data(repeating: 0x05, count: 64))
            return .success(.object(["signedTransaction": .string(signed.base64EncodedString())]))
        }

        try harness.stageInput(name: "__msgA", jsonObject: ["bytes": Array(messageA)], byteArrayFields: ["bytes"])
        try harness.stageInput(name: "__msgB", jsonObject: ["bytes": Array(messageB)], byteArrayFields: ["bytes"])
        // swiftlint:disable all
        try harness.run("""
        function makeTx(messageBytes) {
            return {
                signatures: [{ publicKey: { toBase58: function () { return 'AddressA'; } }, signature: null }],
                serializeMessage: function () { return messageBytes; },
                addSignature: function (publicKey, signature) { this.signatures[0].signature = signature; },
            };
        }

        window.__txA = makeTx(window.__msgA.bytes);
        window.__txB = makeTx(window.__msgB.bytes);
        """)
        // swiftlint:enable all

        try harness.invoke("window.solana.signAllTransactions([window.__txA, window.__txB])")

        let recordedWires = harness.recordedRequests
            .filter { $0.method == "signTransaction" }
            .map { $0.params["transaction"]?.stringValue }
        #expect(recordedWires == [expectedWireA.base64EncodedString(), expectedWireB.base64EncodedString()])
    }

    // MARK: - signAndSendTransaction

    @Test
    func signAndSendTransactionResolvesABase58SignatureString() throws {
        let harness = try makeHarness()
        try connect(harness, address: "AddressA", publicKey: Data(repeating: 0x01, count: 32))

        let signatureBytes = Data(repeating: 0xAB, count: 64)
        harness.handleRequest = { _, method, params in
            #expect(method == "signAndSendTransaction")
            #expect(params["options"]?["commitment"]?.stringValue == "confirmed")
            return .success(.object(["signature": .string(signatureBytes.base64EncodedString())]))
        }

        try harness.stageInput(name: "__sendMsg", jsonObject: ["bytes": [UInt8]([0x01])], byteArrayFields: ["bytes"])
        // swiftlint:disable all
        try harness.run("""
        window.__sendTx = {
            signatures: [{ publicKey: { toBase58: function () { return 'AddressA'; } }, signature: null }],
            serializeMessage: function () { return window.__sendMsg.bytes; },
            addSignature: function () {},
        };
        """)
        // swiftlint:enable all

        let result = try harness.invoke(
            "window.solana.signAndSendTransaction(window.__sendTx, { commitment: 'confirmed' })"
        )

        #expect(result["signature"]?.stringValue == Base58.encode(signatureBytes))
    }
}
