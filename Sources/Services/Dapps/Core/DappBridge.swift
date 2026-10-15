//
//  DappBridge.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 25.09.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation
import WebKit

/// The single `reefr` `WKScriptMessageHandlerWithReply`, one per browser
/// window/tab. Decodes `{namespace, method, params}`, dispatches to the
/// enabled namespace's ``DappProvider``, and pushes provider-originated
/// events back into the page via `window.__reefr._emit`.
@MainActor
final class DappBridge: NSObject {
    /// The result of ``dispatch(namespaceRaw:method:params:origin:)`` —
    /// split from ``WKScriptMessageHandlerWithReply``'s single
    /// `(Any?, String?)` reply shape so the dispatch core is testable
    /// without a real `WKScriptMessage` (which has no public initializer).
    enum DispatchOutcome: Equatable {
        case success(JSONValue)
        /// A transport-level failure (bad/unknown namespace) — reported
        /// to the page as a rejected promise with a plain string, unlike
        /// a provider-level ``DappError``.
        case transportError(String)
        case providerError(JSONValue)
    }

    private let providers: [DappNamespace: any DappProvider]
    let session: DappSession
    private let approving: any DappApproving
    private let signingService: DappSigningService
    private weak var webView: WKWebView?

    /// Fired when a provider's own request handling (not the UI
    /// selector) changes `session`'s active account — today, only
    /// `wallet_switchEthereumChain`. The handler must only update local
    /// display state: calling back into `session.setActiveAccount`
    /// here would re-enter this same dispatch-driven mutation and loop.
    var onProviderDrivenAccountChange: ((Account?) -> Void)?

    init(
        providers: [any DappProvider],
        session: DappSession,
        approving: any DappApproving,
        signingService: DappSigningService
    ) {
        self.providers = Dictionary(uniqueKeysWithValues: providers.map { (type(of: $0).namespace, $0) })
        self.session = session
        self.approving = approving
        self.signingService = signingService
        super.init()
    }

    /// Installs this bridge as `webView`'s `reefr` message handler, in
    /// the `.page` content world so only the page's own script (not this
    /// app's injected `bridge.js`/provider scripts, which run in `.page`
    /// too by design — see `DappScripts`) is otherwise distinguished.
    func attach(to webView: WKWebView) {
        self.webView = webView
        webView.configuration.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "reefr")
    }

    /// Notifies every enabled namespace's provider that `session`
    /// changed (an account switch in the account picker, or a
    /// navigation that updated the origin) and pushes whatever events
    /// come back into the page.
    func sessionDidChange() async {
        let snapshot = await session.snapshot()
        for (namespace, provider) in providers {
            for event in provider.sessionDidChange(snapshot) {
                emit(event, namespace: namespace)
            }
        }
    }

    /// The dispatch core: looks up `namespaceRaw`'s provider, updates
    /// `session`'s origin, calls the provider, and notifies every
    /// provider of whatever the request itself changed in `session`
    /// (e.g. `wallet_switchEthereumChain` or granting a `.connect`).
    func dispatch(namespaceRaw: String, method: String, params: JSONValue, origin: String) async -> DispatchOutcome {
        guard let namespace = DappNamespace(rawValue: namespaceRaw), let provider = providers[namespace] else {
            return .transportError("reefr: unknown namespace \(namespaceRaw)")
        }

        let originChanged = await session.updateOrigin(origin)
        if originChanged {
            await sessionDidChange()
        }

        let beforeSnapshot = originChanged ? nil : await session.snapshot()

        let context = DappRequestContext(
            origin: origin, session: session, approving: approving, signingService: signingService
        )

        let outcome: DispatchOutcome
        do {
            let result = try await provider.handle(method: method, params: params, context: context)
            outcome = .success(result)
        } catch {
            printDebug("\(namespace.rawValue).\(method) from \(origin) failed: \(error)")
            outcome = .providerError(provider.wireError(error))
        }

        if let beforeSnapshot {
            let afterSnapshot = await session.snapshot()
            if afterSnapshot != beforeSnapshot {
                await sessionDidChange()

                if afterSnapshot.activeAccount != beforeSnapshot.activeAccount {
                    onProviderDrivenAccountChange?(afterSnapshot.activeAccount)
                }
            }
        }

        return outcome
    }

    private func emit(_ event: DappEvent, namespace: DappNamespace) {
        guard
            let payloadData = try? event.payload.encoded(),
            let payloadJSON = String(data: payloadData, encoding: .utf8)
        else {
            return
        }

        let script = "window.__reefr._emit(\"\(namespace.rawValue)\", \"\(event.name)\", \(payloadJSON))"
        webView?.evaluateJavaScript(script, in: nil, in: .page, completionHandler: nil)
    }
}

// MARK: - WKScriptMessageHandlerWithReply

extension DappBridge: WKScriptMessageHandlerWithReply {
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        guard message.frameInfo.isMainFrame else {
            replyHandler(nil, "reefr: messages are only accepted from the main frame")
            return
        }

        guard
            let body = message.body as? [String: Any],
            let namespaceRaw = body["namespace"] as? String,
            let method = body["method"] as? String
        else {
            replyHandler(nil, "reefr: malformed request")
            return
        }

        let params = JSONValue(any: body["params"] ?? [Any]())
        let origin = message.frameInfo.securityOrigin
        let originString = "\(origin.protocol)://\(origin.host):\(origin.port)"

        Task {
            switch await dispatch(namespaceRaw: namespaceRaw, method: method, params: params, origin: originString) {
            case let .success(value):
                replyHandler(["ok": true, "value": value.anyValue], nil)
            case let .transportError(message):
                replyHandler(nil, message)
            case let .providerError(wireError):
                replyHandler(["ok": false, "error": wireError.anyValue], nil)
            }
        }
    }
}
