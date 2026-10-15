// Tests for Resources/Browser/providers/tron.js, run with the real bundled
// TronWeb (vendor/tronweb.js) via DappWalletStandardJSHarness: the
// TronLink-shaped surface the TronLink wallet adapter detects, the
// connect handshake, and that TronWeb's signing and node HTTP are routed
// to native.

import Foundation
import JavaScriptCore
import Testing
@testable import ReefrWallet

struct TronProviderScriptTests {
    static let address = "TMVQGm1qAQYVdetCeGRRkTWYYrLXuHK2HC"
    static let hex = "417e5f4552091a69125d5dfcb7b8c2659029395bdf"

    private func makeHarness() throws -> DappWalletStandardJSHarness {
        try DappWalletStandardJSHarness(providerResourceNames: ["vendor/tronweb.js", "providers/tron.js"])
    }

    private func value(_ harness: DappWalletStandardJSHarness, _ expression: String) -> String? {
        harness.context.evaluateScript("String(\(expression))")?.toString()
    }

    private func connect(_ harness: DappWalletStandardJSHarness) throws -> JSONValue {
        harness.handleRequest = { _, method, _ in
            guard method == "connect" else {
                return .failure(.object(["code": .number(-32603), "message": .string("unexpected \(method)")]))
            }

            return .success(.object(["address": .string(Self.address), "hex": .string(Self.hex)]))
        }

        return try harness.invoke("window.tronLink.request({ method: 'tron_requestAccounts' })")
    }

    @Test
    func injectsAnHonestTronLinkShapedProvider() throws {
        let harness = try makeHarness()

        #expect(value(harness, "window.tronLink.isReefr") == "true")
        #expect(value(harness, "window.tronLink.isTronLink") == "undefined")
        #expect(value(harness, "window.tron.isTronLink") == "undefined")
        #expect(value(harness, "window.tronLink.ready") == "false")
        #expect(value(harness, "window.TronWeb") == "undefined")
        #expect(value(harness, "window.tronWeb.defaultAddress.base58") == "false")

        // Network first, then a silent reconnect attempt.
        #expect(harness.recordedRequests.map(\.method) == ["network", "connect"])
        #expect(harness.recordedRequests.last?.params["onlyIfTrusted"] == .bool(true))
    }

    @Test
    func requestAccountsConnectsTronWeb() throws {
        let harness = try makeHarness()

        let result = try connect(harness)

        #expect(result["code"] == .number(200))
        #expect(value(harness, "window.tronLink.ready") == "true")
        #expect(value(harness, "window.tronLink.tronWeb.defaultAddress.base58") == Self.address)
        #expect(value(harness, "window.tronWeb.defaultAddress.hex") == Self.hex)
        #expect(value(harness, "window.tron.tronWeb === window.tronWeb") == "true")
    }

    @Test
    func requestAccountsReportsRejectionAsTronLinkDoes() throws {
        let harness = try makeHarness()
        harness.handleRequest = { _, _, _ in
            .failure(.object(["code": .number(4001), "message": .string("User rejected the request.")]))
        }

        let result = try harness.invoke("window.tronLink.request({ method: 'tron_requestAccounts' })")

        #expect(result["code"] == .number(4001))
        #expect(value(harness, "window.tronLink.ready") == "false")
    }

    @Test
    func trxSignForwardsRawDataAndAttachesTheSignature() throws {
        let harness = try makeHarness()
        _ = try connect(harness)

        let signature = String(repeating: "ab", count: 65)
        harness.handleRequest = { _, method, _ in
            method == "signTransaction" ? .success(.object(["signature": .string(signature)])) : .success(.null)
        }

        let result = try harness.invoke(
            "window.tronWeb.trx.sign({ txID: 'aa', raw_data: {}, raw_data_hex: '0a02' })",
            resultTransform: "{ signature: value.signature, txID: value.txID }"
        )

        #expect(result["signature"] == .array([.string(signature)]))
        #expect(result["txID"] == .string("aa"))
        #expect(harness.recordedRequests.last?.params["transaction"] == .object([
            "txID": .string("aa"),
            "raw_data_hex": .string("0a02")
        ]))
    }

    @Test
    func trxSignRefusesHexStringsAndSignedTransactions() throws {
        let harness = try makeHarness()
        _ = try connect(harness)
        let before = harness.recordedRequests.count

        #expect(throws: DappWalletStandardJSHarnessError.self) {
            try harness.invoke("window.tronWeb.trx.sign('deadbeef')")
        }
        #expect(throws: DappWalletStandardJSHarnessError.self) {
            try harness.invoke("window.tronWeb.trx.sign({ raw_data_hex: '0a02', signature: ['00'] })")
        }
        #expect(harness.recordedRequests.count == before)
    }

    @Test
    func signMessageV2SendsUTF8BytesAsHex() throws {
        let harness = try makeHarness()
        _ = try connect(harness)
        harness.handleRequest = { _, _, _ in .success(.object(["signature": .string("0x01")])) }

        let result = try harness.invoke("window.tronWeb.trx.signMessageV2('héllo')")

        #expect(result == .string("0x01"))
        #expect(harness.recordedRequests.last?.params["message"] == .string("68c3a96c6c6f"))
    }

    @Test
    func tronWebNodeRequestsGoThroughNative() throws {
        let harness = try makeHarness()
        _ = try connect(harness)
        harness.handleRequest = { _, method, _ in
            method == "nodeRequest" ? .success(.object(["balance": .number(1_234_567)])) : .success(.null)
        }

        let result = try harness.invoke("window.tronWeb.trx.getBalance('\(Self.address)')")

        #expect(result == .number(1_234_567))
        let request = harness.recordedRequests.last
        #expect(request?.method == "nodeRequest")
        #expect(request?.params["method"] == .string("post"))
        #expect(request?.params["path"]?.stringValue?.hasSuffix("/getaccount") == true)
    }

    @Test
    func nativeChangeEventDisconnects() throws {
        let harness = try makeHarness()
        _ = try connect(harness)

        try harness.emit(
            namespace: "tron",
            event: "change",
            payload: .object([
                "account": .null,
                "chainId": .string("0x2b6653dc"),
                "host": .string("https://api.trongrid.io")
            ])
        )

        #expect(value(harness, "window.tronLink.ready") == "false")
        #expect(value(harness, "window.tronWeb.defaultAddress.base58") == "false")
    }
}
