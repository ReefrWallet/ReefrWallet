// A minimal JavaScriptCore harness for executing the injected Wallet
// Standard provider scripts (`Resources/Browser/providers/wallet-standard-core.js`,
// `Resources/Browser/providers/*.js`) directly, without a WKWebView —
// `WKScriptMessage` has no public initializer, so DappBridgeTests.swift's
// existing dispatch-core tests never actually run the JS side; this
// harness is what lets a test assert on the *script's* behavior (declared
// feature shapes, variadic input handling, byte conversions, option
// forwarding) instead.
//
// `JSContext` has no `window`/DOM: this installs just enough of a browser
// shim for these specific scripts to run — `window` aliased to the global
// object, `btoa`/`atob`, `TextEncoder`/`TextDecoder`, and a synchronous
// `addEventListener`/`dispatchEvent`/`CustomEvent` sufficient for
// `registerWallet`'s usage.
// `window.__reefr.request` is backed by a native block the test controls
// per call (`handleRequest`); since every response is produced
// synchronously with no real async I/O, the resulting `Promise` chains
// resolve synchronously within the same `JSContext` call that triggers
// them — no run-loop spinning needed to observe a result.

import Foundation
import JavaScriptCore
@testable import ReefrWallet

// `Swift.Error`, not `Error`: `ReefrWallet` declares its own `enum Error`
// (`Sources/Extensions/.../Error.swift`-style app error), which shadows
// the standard library protocol for any unqualified `Error` once
// `@testable import ReefrWallet` is in scope.
struct DappWalletStandardJSHarnessError: Swift.Error, CustomStringConvertible {
    let description: String
}

/// What a stubbed `window.__reefr.request(...)` call should resolve or
/// reject the script's `Promise` with. Not `Swift.Result` — the rejection
/// side is a JS-facing value (what `Promise.reject(...)` receives), not a
/// Swift `Error`.
enum DappWalletStandardJSHarnessRequestOutcome {
    case success(JSONValue)
    case failure(JSONValue)
}

/// A single `window.__reefr.request(namespace, method, params)` call the
/// loaded script has made.
struct DappWalletStandardJSHarnessRecordedRequest {
    let namespace: String
    let method: String
    let params: JSONValue
}

final class DappWalletStandardJSHarness {
    let context: JSContext

    /// Every `window.__reefr.request(namespace, method, params)` call the
    /// loaded script has made, in order.
    private(set) var recordedRequests: [DappWalletStandardJSHarnessRecordedRequest] = []

    /// Answers each recorded request. Defaults to resolving every call
    /// with `.null`; tests override this per scenario.
    var handleRequest: (String, String, JSONValue) -> DappWalletStandardJSHarnessRequestOutcome = { _, _, _ in
        .success(.null)
    }

    private var pendingException: String?

    /// Loads `wallet-standard-core.js` followed by each of
    /// `providerResourceNames` (paths relative to `Resources/Browser/`,
    /// e.g. `"providers/solana.js"`), in order — mirroring the load order
    /// `DappScripts.swift` injects them in.
    init(providerResourceNames: [String]) throws {
        context = JSContext()
        context.exceptionHandler = { [weak self] _, exception in
            self?.pendingException = exception?.toString() ?? "unknown JavaScript exception"
        }

        try evaluate(Self.polyfillSource, name: "polyfills")
        installNativeRequestBridge()
        try evaluate(Self.captureRegisteredWalletSource, name: "capture-wallet")

        try evaluate(resource: "providers/wallet-standard-core.js")
        for name in providerResourceNames {
            try evaluate(resource: name)
        }
    }

    /// Evaluates an arbitrary synchronous script (test setup/assertions
    /// that don't involve a promise — e.g. registering a listener or
    /// reading a plain value back) and surfaces any thrown JS exception.
    /// For a script that returns a `Promise`, use ``invoke(_:resultTransform:)``
    /// instead.
    func run(_ script: String) throws {
        try evaluate(script, name: "run")
    }

    /// The `Wallet` object the loaded provider script registered via
    /// `window.__reefrWalletStandard.registerWallet`, or `nil` if the
    /// script declined to register (e.g. `window.__reefr` was missing).
    var registeredWallet: JSValue? {
        let wallet = context.evaluateScript("__capturedWallet")
        return (wallet?.isNull ?? true) ? nil : wallet
    }

    /// Simulates a native `window.__reefr._emit(namespace, event, payload)`
    /// push — the counterpart of `DappBridge`'s real event delivery,
    /// reproduced minimally here so a `standard:events` listener
    /// registered via `on(...)` can be exercised.
    func emit(namespace: String, event: String, payload: JSONValue) throws {
        guard let testEmit = context.objectForKeyedSubscript("__testEmit"), !testEmit.isUndefined else {
            throw DappWalletStandardJSHarnessError(description: "__testEmit was not installed")
        }

        let payloadValue = JSValue(object: payload.anyValue, in: context)
        testEmit.call(withArguments: [namespace, event, payloadValue as Any])
        try checkForPendingException()
    }

    /// Stages a JSON-shaped input as `window.<name>`, upgrading each field
    /// named in `byteArrayFields` from a plain JSON number array to a real
    /// `Uint8Array` — the variadic feature methods call byte-array-only
    /// methods (e.g. `bytesToBase64`'s `.subarray`) on their inputs, so a
    /// plain array wouldn't exercise the same code path a real dapp's
    /// `Uint8Array` does.
    func stageInput(name: String, jsonObject: [String: Any], byteArrayFields: [String]) throws {
        let data = try JSONSerialization.data(withJSONObject: jsonObject, options: [.fragmentsAllowed])
        let json = String(data: data, encoding: .utf8) ?? "{}"
        var script = "window.\(name) = \(json);\n"

        for field in byteArrayFields {
            script += "window.\(name).\(field) = new Uint8Array(window.\(name).\(field));\n"
        }

        try evaluate(script, name: "stage-\(name)")
    }

    /// Evaluates `callExpression` (a JS expression yielding a `Promise`),
    /// applies `transform` to its resolved value (a JS expression using
    /// `value` as the resolved value — by default the identity), and
    /// returns the transformed result as a ``JSONValue``.
    ///
    /// Call and resolution are wired up within a single `evaluateScript`
    /// invocation because a promise chain only drains its microtask queue
    /// synchronously when created and observed inside the same top-level
    /// script execution — attaching `.then()` from native code in a
    /// *separate* call after the promise already exists does not resolve
    /// synchronously and would need real run-loop spinning to observe.
    ///
    /// `transform` should convert any `Uint8Array` fields in the resolved
    /// value to base64 (via `window.__reefrWalletStandard.bytesToBase64`)
    /// before handing back to native, since typed arrays don't bridge
    /// through `JSValue.toObject()` the way plain JSON values do — this
    /// also implicitly verifies the resolved fields really are
    /// `Uint8Array`s (a plain array has no `.subarray`, so
    /// `bytesToBase64` throws if the script returned the wrong shape).
    ///
    /// - Throws: ``DappWalletStandardJSHarnessError`` if the promise
    ///   rejects, or doesn't resolve synchronously.
    @discardableResult
    func invoke(_ callExpression: String, resultTransform transform: String = "value") throws -> JSONValue {
        var capturedResult: JSValue?
        var capturedError: JSValue?

        let onFulfilled: @convention(block) (JSValue) -> Void = { value in capturedResult = value }
        let onRejected: @convention(block) (JSValue) -> Void = { value in capturedError = value }
        context.setObject(onFulfilled, forKeyedSubscript: "__onFulfilled" as NSString)
        context.setObject(onRejected, forKeyedSubscript: "__onRejected" as NSString)

        try evaluate(
            "(\(callExpression)).then(function (value) { __onFulfilled(\(transform)); }, __onRejected);",
            name: "invoke"
        )

        if let capturedError {
            throw DappWalletStandardJSHarnessError(description: "JS promise rejected: \(capturedError.toString() ?? "?")")
        }

        guard let capturedResult else {
            throw DappWalletStandardJSHarnessError(description: "JS promise for `\(callExpression)` did not resolve synchronously")
        }

        return JSONValue(any: capturedResult.toObject() ?? NSNull())
    }

    // MARK: - Setup

    private typealias NativeRequestBlock = @convention(block) (String, String, JSValue) -> JSValue

    private func installNativeRequestBridge() {
        let requestBlock: NativeRequestBlock = { [weak self] namespace, method, paramsValue in
            let context = JSContext.current() ?? self?.context
            guard let self else {
                return JSValue(nullIn: context)
            }

            let params = JSONValue(any: paramsValue.toObject() ?? NSNull())
            recordedRequests.append(
                DappWalletStandardJSHarnessRecordedRequest(namespace: namespace, method: method, params: params)
            )

            switch handleRequest(namespace, method, params) {
            case let .success(value):
                return JSValue(object: ["ok": true, "value": value.anyValue], in: self.context)
            case let .failure(value):
                return JSValue(object: ["ok": false, "value": value.anyValue], in: self.context)
            }
        }

        context.setObject(requestBlock, forKeyedSubscript: "__nativeRequest" as NSString)

        // swiftlint:disable closing_scope_newline

        // `window.__reefr.on` records listeners per "namespace:event" key;
        // `__testEmit` (called from `emit(namespace:event:payload:)`) is
        // this harness's stand-in for native pushing an event.
        context.evaluateScript("""
        window.__reefr = {
            request: function (namespace, method, params) {
                var outcome = __nativeRequest(namespace, method, params);
                if (outcome.ok) {
                    return Promise.resolve(outcome.value);
                }
                return Promise.reject(outcome.value);
            },
            on: function (namespace, event, listener) {
                var key = namespace + ':' + event;
                window.__reefrListeners[key] = window.__reefrListeners[key] || [];
                window.__reefrListeners[key].push(listener);
                return function () {
                    var listeners = window.__reefrListeners[key] || [];
                    var index = listeners.indexOf(listener);
                    if (index !== -1) {
                        listeners.splice(index, 1);
                    }
                };
            },
        };
        window.__reefrListeners = {};
        window.__testEmit = function (namespace, event, payload) {
            var listeners = window.__reefrListeners[namespace + ':' + event] || [];
            listeners.slice().forEach(function (listener) {
                listener(payload);
            });
        };
        """)
        // swiftlint:enable closing_scope_newline
    }

    private func evaluate(_ source: String, name: String) throws {
        pendingException = nil
        context.evaluateScript(source, withSourceURL: URL(string: name))
        try checkForPendingException()
    }

    private func evaluate(resource name: String) throws {
        let url = Self.resourcesDirectory.appendingPathComponent(name)
        let source = try String(contentsOf: url, encoding: .utf8)
        try evaluate(source, name: name)
    }

    private func checkForPendingException() throws {
        if let pendingException {
            self.pendingException = nil
            throw DappWalletStandardJSHarnessError(description: pendingException)
        }
    }

    /// `Resources/Browser/` in the checked-out repository — read directly
    /// from source rather than the app bundle, mirroring
    /// `AnvilTestSupport.swift`'s `startAnvilNode()`, which locates the
    /// repository root the same way.
    private static var resourcesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // DappWalletStandardJSHarness.swift -> Support/
            .deletingLastPathComponent() // Support/ -> Tests/
            .deletingLastPathComponent() // Tests/ -> repository root
            .appendingPathComponent("Resources/Browser")
    }

    // swiftlint:disable closing_scope_newline

    private static let captureRegisteredWalletSource = """
    var __capturedWallet = null;
    window.addEventListener('wallet-standard:register-wallet', function (event) {
        event.detail({ register: function (wallet) { __capturedWallet = wallet; } });
    });
    """

    /// Just enough of a browser environment for `wallet-standard-core.js`
    /// and the `providers/*.js` scripts to run under plain `JSContext`.
    private static let polyfillSource = """
    var window = this;

    var __base64Alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

    window.btoa = function (binary) {
        var result = '';
        var i = 0;
        for (; i + 3 <= binary.length; i += 3) {
            var n = (binary.charCodeAt(i) << 16) | (binary.charCodeAt(i + 1) << 8) | binary.charCodeAt(i + 2);
            result += __base64Alphabet[(n >> 18) & 63] + __base64Alphabet[(n >> 12) & 63]
                + __base64Alphabet[(n >> 6) & 63] + __base64Alphabet[n & 63];
        }
        var remaining = binary.length - i;
        if (remaining === 1) {
            var n1 = binary.charCodeAt(i) << 16;
            result += __base64Alphabet[(n1 >> 18) & 63] + __base64Alphabet[(n1 >> 12) & 63] + '==';
        } else if (remaining === 2) {
            var n2 = (binary.charCodeAt(i) << 16) | (binary.charCodeAt(i + 1) << 8);
            result += __base64Alphabet[(n2 >> 18) & 63] + __base64Alphabet[(n2 >> 12) & 63]
                + __base64Alphabet[(n2 >> 6) & 63] + '=';
        }
        return result;
    };

    window.atob = function (base64) {
        var clean = base64.replace(/=+$/, '');
        var result = '';
        var bits = 0;
        var value = 0;
        for (var i = 0; i < clean.length; i++) {
            value = (value << 6) | __base64Alphabet.indexOf(clean[i]);
            bits += 6;
            if (bits >= 8) {
                bits -= 8;
                result += String.fromCharCode((value >> bits) & 0xFF);
            }
        }
        return result;
    };

    // UTF-8 only, which is all the providers and the bundled SDKs use.
    if (typeof TextEncoder === 'undefined') {
        window.TextEncoder = function () {};
        window.TextEncoder.prototype.encode = function (text) {
            var binary = unescape(encodeURIComponent(text));
            var bytes = new Uint8Array(binary.length);
            for (var i = 0; i < binary.length; i++) {
                bytes[i] = binary.charCodeAt(i);
            }
            return bytes;
        };
    }

    if (typeof TextDecoder === 'undefined') {
        window.TextDecoder = function () {};
        window.TextDecoder.prototype.decode = function (bytes) {
            var binary = '';
            for (var i = 0; i < bytes.length; i++) {
                binary += String.fromCharCode(bytes[i]);
            }
            return decodeURIComponent(escape(binary));
        };
    }

    var __eventListeners = {};
    window.addEventListener = function (type, listener) {
        __eventListeners[type] = __eventListeners[type] || [];
        __eventListeners[type].push(listener);
    };
    window.dispatchEvent = function (event) {
        (__eventListeners[event.type] || []).slice().forEach(function (listener) {
            listener(event);
        });
    };
    window.CustomEvent = function (type, init) {
        this.type = type;
        this.detail = init && init.detail;
    };
    """
}

// swiftlint:enable closing_scope_newline
