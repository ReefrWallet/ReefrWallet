// Tests for Resources/Browser/providers/cardano.js, run via
// DappWalletStandardJSHarness: the CIP-30 surface, positional params and
// conversion of native wire errors into per-method CIP-30 error objects.

import Foundation
import JavaScriptCore
import Testing
@testable import ReefrWallet

struct CardanoProviderScriptTests {
    private func makeHarness() throws -> DappWalletStandardJSHarness {
        try DappWalletStandardJSHarness(providerResourceNames: ["providers/cardano.js"])
    }

    private func value(_ harness: DappWalletStandardJSHarness, _ expression: String) -> String? {
        harness.context.evaluateScript("String(\(expression))")?.toString()
    }

    /// Calls `method` on the enabled API (or the wallet object for
    /// `enable`/`isEnabled`) against a native stub failing with `wire`;
    /// returns the JS rejection reason.
    private func rejection(_ method: String, wire: JSONValue) throws -> JSONValue {
        let harness = try makeHarness()
        harness.handleRequest = { _, _, _ in .success(.null) }
        try enabled(harness)
        harness.handleRequest = { _, _, _ in .failure(wire) }
        let target = ["enable", "isEnabled"].contains(method) ? "window.cardano.reefr" : "window.__api"
        try harness.run("window.__out = null; \(target).\(method)('x', 'y').catch(function (e) { window.__out = e; });")
        let json = harness.context.evaluateScript("JSON.stringify(window.__out)")?.toString() ?? "null"
        return JSONValue(any: try JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed]))
    }

    private func wire(_ code: Int, _ info: String = "x") -> JSONValue {
        .object(["code": .number(Double(code)), "info": .string(info)])
    }

    private func enabled(_ harness: DappWalletStandardJSHarness) throws {
        try harness.run("window.__api = null; window.cardano.reefr.enable().then(function (a) { window.__api = a; });")
    }

    @Test
    func exposesFrozenHonestWalletObject() throws {
        let harness = try makeHarness()

        #expect(value(harness, "Object.isFrozen(window.cardano.reefr)") == "true")
        #expect(value(harness, "window.cardano.reefr.name") == "Reefr Wallet")
        #expect(value(harness, "window.cardano.reefr.apiVersion") == "1")
        #expect(value(harness, "JSON.stringify(window.cardano.reefr.supportedExtensions)") == "[]")
        #expect(value(harness, "typeof window.cardano.reefr.enable") == "function")
        #expect(value(harness, "typeof window.cardano.reefr.isEnabled") == "function")
    }

    @Test
    func keepsOtherWalletsAndExistingEntry() throws {
        let harness = try DappWalletStandardJSHarness(providerResourceNames: [])
        try harness.run("window.cardano = { other: { name: 'Other' }, reefr: { name: 'Pre' } };")
        let script = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Browser/providers/cardano.js"), encoding: .utf8)
        try harness.run(script)

        #expect(value(harness, "window.cardano.other.name") == "Other")
        #expect(value(harness, "window.cardano.reefr.name") == "Pre")
    }

    @Test
    func enableResolvesFrozenApiWithoutCollateral() throws {
        let harness = try makeHarness()
        harness.handleRequest = { _, _, _ in .success(.null) }
        try enabled(harness)

        #expect(value(harness, "Object.isFrozen(window.__api)") == "true")
        #expect(value(harness, "typeof window.__api.getCollateral") == "undefined")
        #expect(value(harness, "Object.keys(window.__api).sort().join()")
            == "getBalance,getChangeAddress,getExtensions,getNetworkId,getRewardAddresses,"
            + "getUnusedAddresses,getUsedAddresses,getUtxos,signData,signTx,submitTx")
    }

    @Test
    func enableIgnoresUnsupportedExtensions() throws {
        let harness = try makeHarness()
        try harness.run("window.cardano.reefr.enable({ extensions: [{ cip: 95 }] });")

        #expect(harness.recordedRequests.map(\.method) == ["enable"])
        #expect(harness.recordedRequests.first?.namespace == "cardano")
        #expect(harness.recordedRequests.first?.params == .array([]))
    }

    @Test
    func getExtensionsResolvesEmptyWithoutNative() throws {
        let harness = try makeHarness()
        try enabled(harness)
        let before = harness.recordedRequests.count

        let result = try harness.invoke("window.__api.getExtensions()")

        #expect(result == .array([]))
        #expect(harness.recordedRequests.count == before)
    }

    @Test
    func isEnabledForwardsToNative() throws {
        let harness = try makeHarness()
        harness.handleRequest = { _, _, _ in .success(.bool(true)) }

        let result = try harness.invoke("window.cardano.reefr.isEnabled()")

        #expect(result == .bool(true))
        #expect(harness.recordedRequests.last?.method == "isEnabled")
    }

    @Test
    func passesParamsPositionally() throws {
        let harness = try makeHarness()
        try enabled(harness)
        harness.handleRequest = { _, _, _ in .success(.null) }

        let cases: [(String, String, JSONValue)] = [
            ("getBalance()", "getBalance", .array([])),
            ("getChangeAddress()", "getChangeAddress", .array([])),
            ("getNetworkId()", "getNetworkId", .array([])),
            ("getRewardAddresses()", "getRewardAddresses", .array([])),
            ("getUnusedAddresses()", "getUnusedAddresses", .array([])),
            ("getUsedAddresses()", "getUsedAddresses", .array([.null])),
            ("getUsedAddresses({ page: 1, limit: 5 })", "getUsedAddresses",
             .array([.object(["page": .number(1), "limit": .number(5)])])),
            ("getUtxos()", "getUtxos", .array([.null, .null])),
            ("getUtxos('00', { page: 0, limit: 2 })", "getUtxos",
             .array([.string("00"), .object(["page": .number(0), "limit": .number(2)])])),
            ("signTx('84')", "signTx", .array([.string("84"), .bool(false)])),
            ("signTx('84', true)", "signTx", .array([.string("84"), .bool(true)])),
            ("signData('addr', 'beef')", "signData", .array([.string("addr"), .string("beef")])),
            ("submitTx('84')", "submitTx", .array([.string("84")])),
        ]

        for (call, method, params) in cases {
            _ = try harness.invoke("window.__api.\(call)")
            let request = harness.recordedRequests.last
            #expect(request?.namespace == "cardano")
            #expect(request?.method == method, "\(call)")
            #expect(request?.params == params, "\(call)")
        }
    }

    @Test
    func returnsNativeValuesUnchanged() throws {
        let harness = try makeHarness()
        try enabled(harness)
        harness.handleRequest = { _, _, _ in .success(.array([.string("a1"), .string("b2")])) }

        #expect(try harness.invoke("window.__api.getUtxos()") == .array([.string("a1"), .string("b2")]))
    }

    @Test
    func apiErrorForEnableReadsAndOthers() throws {
        let methods = [
            "enable", "getBalance", "getChangeAddress", "getNetworkId", "getRewardAddresses",
            "getUnusedAddresses", "getUsedAddresses", "getUtxos", "isEnabled",
        ]
        for method in methods {
            for code in [-4, -3, -2, -1] {
                #expect(try rejection(method, wire: wire(code, "e")) == wire(code, "e"), "\(method) \(code)")
            }
        }
    }

    @Test
    func dataSignErrorForSignData() throws {
        for code in [1, 2, 3] {
            #expect(try rejection("signData", wire: wire(code, "no")) == wire(code, "no"))
        }
    }

    @Test
    func paginateErrorForPagedMethods() throws {
        let paginate = JSONValue.object(["maxSize": .number(3)])
        for method in ["getUsedAddresses", "getUtxos"] {
            #expect(try rejection(method, wire: paginate) == paginate)
        }
    }

    @Test
    func txSendErrorForSubmitTx() throws {
        for code in [1, 2] {
            #expect(try rejection("submitTx", wire: wire(code, "no")) == wire(code, "no"))
        }
    }

    @Test
    func txSignErrorForSignTx() throws {
        for code in [1, 2] {
            #expect(try rejection("signTx", wire: wire(code, "no")) == wire(code, "no"))
        }
    }

    @Test
    func convertsBridgeErrorObjects() throws {
        // `bridge.js` rejects with an `Error` carrying `code`; message = info.
        let harness = try makeHarness()
        harness.handleRequest = { _, _, _ in .success(.null) }
        try enabled(harness)
        try harness.run("""
        window.__reefr.request = function () {
            var e = new Error('declined'); e.code = 2; return Promise.reject(e);
        };
        window.__out = null;
        window.__api.signTx('84').catch(function (e) { window.__out = e; });
        """)

        #expect(harness.context.evaluateScript("JSON.stringify(window.__out)")?.toString()
            == "{\"code\":2,\"info\":\"declined\"}")
    }

    @Test
    func codelessFailuresFallBackPerClass() throws {
        let harness = try makeHarness()
        harness.handleRequest = { _, _, _ in .success(.null) }
        try enabled(harness)
        try harness.run("""
        window.__reefr.request = function () { return Promise.reject('boom'); };
        window.__outs = {};
        ['getBalance', 'signTx', 'signData', 'submitTx'].forEach(function (m) {
            window.__api[m]('x', 'y').catch(function (e) { window.__outs[m] = e; });
        });
        """)

        #expect(harness.context.evaluateScript("JSON.stringify(window.__outs)")?.toString()
            == "{\"getBalance\":{\"code\":-2,\"info\":\"boom\"},\"signTx\":{\"code\":1,\"info\":\"boom\"},"
            + "\"signData\":{\"code\":1,\"info\":\"boom\"},\"submitTx\":{\"code\":2,\"info\":\"boom\"}}")
    }
}
