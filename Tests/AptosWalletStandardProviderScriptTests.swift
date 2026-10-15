// Runs Resources/Browser/providers/aptos.js in a bare JSContext
// (DappWalletStandardJSHarness) against a scripted native side.

import Foundation
import JavaScriptCore
import Testing
@testable import ReefrWallet

struct AptosWalletStandardProviderScriptTests {
    private static let address = Data(repeating: 0xAB, count: 32)
    private static let publicKey = Data(repeating: 0x11, count: 32)
    private static let publicKeyBcs = Data([0x20]) + publicKey

    private static let accountJSON: JSONValue = .object([
        "address": .string(address.base64EncodedString()),
        "addressString": .string("0x" + String(repeating: "ab", count: 32)),
        "chain": .string("aptos:testnet"),
        "publicKey": .string(publicKey.base64EncodedString()),
        "publicKeyBcs": .string(publicKeyBcs.base64EncodedString())
    ])

    private static let networkJSON: JSONValue = .object([
        "name": .string("testnet"),
        "chainId": .number(2),
        "url": .string("https://api.testnet.aptoslabs.com/v1")
    ])

    private func makeHarness() throws -> DappWalletStandardJSHarness {
        let harness = try DappWalletStandardJSHarness(providerResourceNames: ["providers/aptos.js"])
        harness.handleRequest = { _, method, _ in
            switch method {
            case "connect": .success(.object(["account": Self.accountJSON, "network": Self.networkJSON]))
            case "account": .success(.object(["account": Self.accountJSON]))
            case "network": .success(Self.networkJSON)
            default: .success(.null)
            }
        }

        return harness
    }

    @Test func declaresTheRequiredAip62Features() throws {
        let harness = try makeHarness()
        let wallet = try #require(harness.registeredWallet)

        #expect(wallet.objectForKeyedSubscript("chains").toArray() as? [String] == ["aptos:mainnet", "aptos:testnet"])

        let required = [
            "aptos:account": "account", "aptos:connect": "connect", "aptos:disconnect": "disconnect",
            "aptos:network": "network", "aptos:onAccountChange": "onAccountChange",
            "aptos:onNetworkChange": "onNetworkChange", "aptos:signMessage": "signMessage",
            "aptos:signTransaction": "signTransaction"
        ]

        for (feature, method) in required {
            let value = try #require(wallet.objectForKeyedSubscript("features").objectForKeyedSubscript(feature))
            #expect(value.objectForKeyedSubscript("version").toString() == "1.0.0", "\(feature)")
            #expect(value.objectForKeyedSubscript(method).isObject, "\(feature).\(method)")
        }
    }

    @Test func connectReturnsSdkCompatibleAccountInfo() throws {
        let harness = try makeHarness()

        let result = try harness.invoke(
            "__capturedWallet.features['aptos:connect'].connect()",
            resultTransform: """
            ({ status: value.status, address: value.args.address.toString(),
               addressLength: value.args.address.length, isBytes: value.args.address instanceof Uint8Array,
               publicKeyBcs: Array.from(value.args.publicKey.bcsToBytes()),
               publicKeyHex: value.args.publicKey.toString() })
            """
        )

        #expect(result["status"]?.stringValue == "Approved")
        #expect(result["address"]?.stringValue == "0x" + String(repeating: "ab", count: 32))
        #expect(result["addressLength"]?.numberValue == 32)
        #expect(result["isBytes"]?.boolValue == true)
        let publicKeyBcs = result["publicKeyBcs"]?.arrayValue?.compactMap(\.numberValue).map { UInt8($0) }
        #expect(publicKeyBcs == Array(Self.publicKeyBcs))
        #expect(result["publicKeyHex"]?.stringValue == "0x" + String(repeating: "11", count: 32))
    }

    @Test func userRejectionResolvesAsRejected() throws {
        let harness = try makeHarness()
        harness.handleRequest = { _, _, _ in .failure(.object(["code": .number(4001), "message": .string("no")])) }

        let result = try harness.invoke("__capturedWallet.features['aptos:connect'].connect()")
        #expect(result["status"]?.stringValue == "Rejected")
    }

    @Test func otherErrorsReject() throws {
        let harness = try makeHarness()
        harness.handleRequest = { _, _, _ in .failure(.object(["message": .string("boom")])) }

        #expect(throws: DappWalletStandardJSHarnessError.self) {
            try harness.invoke("__capturedWallet.features['aptos:connect'].connect()")
        }
    }

    @Test func signTransactionForwardsRawBytesAndReturnsTheAuthenticator() throws {
        let harness = try makeHarness()
        try harness.invoke("__capturedWallet.features['aptos:connect'].connect()")

        let authenticator = Data([0, 32, 1, 2, 3])
        harness.handleRequest = { _, method, params in
            #expect(method == "signTransaction")
            #expect(params["rawTransaction"]?.stringValue == Data([7, 8, 9]).base64EncodedString())
            #expect(params["account"]?["address"]?.stringValue == "0x" + String(repeating: "ab", count: 32))
            return .success(.object(["authenticator": .string(authenticator.base64EncodedString())]))
        }

        try harness.run(
            // swiftlint:disable:next return_in_3_rows
            "window.tx = { rawTransaction: { bcsToBytes: function () { return new Uint8Array([7, 8, 9]); } } };"
        )

        let result = try harness.invoke(
            "__capturedWallet.features['aptos:signTransaction'].signTransaction(window.tx)",
            resultTransform: "({ status: value.status, bytes: Array.from(value.args.bcsToBytes()) })"
        )

        #expect(result["status"]?.stringValue == "Approved")
        #expect(result["bytes"]?.arrayValue?.compactMap(\.numberValue).map { UInt8($0) } == Array(authenticator))
    }

    @Test(arguments: [
        "{ rawTransaction: window.raw, feePayerAddress: '0x1' }",
        "{ rawTransaction: window.raw, secondarySignerAddresses: ['0x1'] }"
    ])
    func feePayerAndMultiAgentTransactionsAreRefusedLocally(transaction: String) throws {
        let harness = try makeHarness()
        // swiftlint:disable:next return_in_3_rows
        try harness.run("window.raw = { bcsToBytes: function () { return new Uint8Array([1]); } };")

        #expect(throws: DappWalletStandardJSHarnessError.self) {
            try harness.invoke("__capturedWallet.features['aptos:signTransaction'].signTransaction(\(transaction))")
        }

        #expect(!harness.recordedRequests.contains { $0.method == "signTransaction" })
    }

    @Test func signMessageForwardsFlagsAndReturnsTheFullMessage() throws {
        let harness = try makeHarness()
        try harness.invoke("__capturedWallet.features['aptos:connect'].connect()")

        let signature = Data(repeating: 9, count: 64)
        harness.handleRequest = { _, _, params in
            #expect(params["message"]?.stringValue == "hi")
            #expect(params["nonce"]?.stringValue == "42")
            #expect(params["application"]?.boolValue == true)
            #expect(params["address"]?.boolValue == false)
            return .success(.object([
                "fullMessage": .string("APTOS\napplication: https://dapp\nmessage: hi\nnonce: 42"),
                "message": .string("hi"),
                "nonce": .string("42"),
                "application": .string("https://dapp"),
                "signature": .string(signature.base64EncodedString()),
                "signatureBcs": .string((Data([0x40]) + signature).base64EncodedString())
            ]))
        }

        let result = try harness.invoke(
            "__capturedWallet.features['aptos:signMessage']"
                + ".signMessage({ message: 'hi', nonce: '42', application: true })",
            resultTransform: """
            ({ status: value.status, prefix: value.args.prefix, full: value.args.fullMessage,
               application: value.args.application, hasAddress: 'address' in value.args,
               signatureLength: value.args.signature.length,
               signatureBcsLength: value.args.signature.bcsToBytes().length })
            """
        )

        #expect(result["status"]?.stringValue == "Approved")
        #expect(result["prefix"]?.stringValue == "APTOS")
        #expect(result["full"]?.stringValue?.hasPrefix("APTOS\n") == true)
        #expect(result["application"]?.stringValue == "https://dapp")
        #expect(result["hasAddress"]?.boolValue == false)
        #expect(result["signatureLength"]?.numberValue == 64)
        #expect(result["signatureBcsLength"]?.numberValue == 65)
    }

    @Test func disconnectEventClearsAccounts() throws {
        let harness = try makeHarness()
        try harness.invoke("__capturedWallet.features['aptos:connect'].connect()")
        try harness.run("""
        window.changes = [];
        __capturedWallet.features['standard:events'].on('change', function (event) {
            window.changes.push(event.accounts.length);
        });
        """)

        try harness.emit(namespace: "aptos", event: "change", payload: .object(["disconnected": .bool(true)]))

        #expect(harness.context.evaluateScript("__capturedWallet.accounts.length").toInt32() == 0)
        #expect(harness.context.evaluateScript("window.changes[0]").toInt32() == 0)
    }

    @Test func accountChangeNotifiesTheListener() throws {
        let harness = try makeHarness()
        try harness.run("""
        window.seen = [];
        __capturedWallet.features['aptos:onAccountChange'].onAccountChange(function (account) {
            window.seen.push(account.address.toString());
        });
        """)

        try harness.emit(namespace: "aptos", event: "change", payload: .null)

        let seen = harness.context.evaluateScript("window.seen[0]").toString()
        #expect(seen == "0x" + String(repeating: "ab", count: 32))
    }
}
