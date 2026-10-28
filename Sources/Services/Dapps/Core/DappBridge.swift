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
    private let accounts: (any DappAccountSource)?
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
        signingService: DappSigningService,
        accounts: (any DappAccountSource)? = nil
    ) {
        self.accounts = accounts
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

        let connectError = provider.isConnectRequest(method: method, params: params)
            ? await prepareConnection(namespace, origin: origin)
            : nil

        let outcome: DispatchOutcome
        if let connectError {
            outcome = .providerError(provider.wireError(connectError))
        } else {
            do {
                let result = try await DappRequestScope.run(approving: approving) { () async throws(DappError) in
                    try await provider.handle(method: method, params: params, context: context)
                }

                outcome = .success(result)
            } catch {
                printDebug("\(namespace.rawValue).\(method) from \(origin) failed: \(error)")
                outcome = .providerError(provider.wireError(error))
            }
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

    /// How long the first connect request waits for the page's other chains.
    private static let connectCollectionWindow = Duration.milliseconds(300)

    /// Connect requests on chains the dapp isn't connected on yet, gathered so they share one prompt.
    private final class ConnectBatch {
        var namespaces: [DappNamespace]
        var task: Task<ConnectResult, Never>?

        init(namespaces: [DappNamespace]) {
            self.namespaces = namespaces
        }
    }

    private struct ConnectResult {
        var accounts: [DappNamespace: Account] = [:]
        /// Chains the user left "Not connected": their requests are refused.
        var declined: Set<DappNamespace> = []
        var isRejected = false
        var unavailable: Set<DappNamespace> = []
    }

    private var connectBatch: ConnectBatch?

    /// Before a connect request reaches its provider: remembers that the page
    /// uses this chain, and makes sure the user has chosen the account to
    /// connect with. A chain the dapp is already connected on needs nothing;
    /// its remembered account is switched to silently when none is selected.
    /// Otherwise the request joins the others the page makes in the same
    /// moment, and the user chooses an account per chain in one prompt, whose
    /// approval is the consent: the provider then finds the permission in place.
    private func prepareConnection(_ namespace: DappNamespace, origin: String) async -> DappError? {
        await session.noteConnectRequest(namespace)

        guard let accounts, !(await session.isPermitted(namespace)) else {
            return nil
        }

        if await session.selectedAccount(namespace) == nil,
           let address = await session.grantedAddress(namespace),
           let remembered = await accounts.choices(for: namespace).first(where: { $0.account.address == address }) {
            await session.rememberConnection(namespace, account: remembered.account)
            return nil
        }

        let result = await collectConnection(namespace, origin: origin)
        if result.isRejected {
            return .userRejected
        }

        if result.declined.contains(namespace) {
            return .userRejected
        }

        guard result.accounts[namespace] != nil, !result.unavailable.contains(namespace) else {
            return .disconnected
        }

        return nil
    }

    /// Keeps the toolbar on the account the user is already using when it was
    /// chosen on a chain in the prompt (using the prompt's choice if it differs),
    /// else selects the first chain's account.
    private func selectActiveAccount(from chosen: [DappNamespace: Account], order: [DappNamespace]) async {
        if let activeNamespace = await session.activeNamespace, let account = chosen[activeNamespace] {
            if await session.activeAccount != account {
                await session.setActiveAccount(account)
            }

            return
        }

        if let first = order.compactMap({ chosen[$0] }).first {
            await session.setActiveAccount(first)
        }
    }

    private func collectConnection(_ namespace: DappNamespace, origin: String) async -> ConnectResult {
        if let batch = connectBatch {
            if !batch.namespaces.contains(namespace) {
                batch.namespaces.append(namespace)
            }

            return await batch.task?.value ?? ConnectResult()
        }

        let batch = ConnectBatch(namespaces: [namespace])
        connectBatch = batch
        let task = Task { [self] () -> ConnectResult in
            try? await Task.sleep(for: Self.connectCollectionWindow)
            return await resolveConnections(batch, origin: origin)
        }

        batch.task = task
        return await task.value
    }

    private func resolveConnections(_ batch: ConnectBatch, origin: String) async -> ConnectResult {
        let namespaces = batch.namespaces
        connectBatch = nil

        var result = ConnectResult()
        var selections: [DappAccountSelection] = []

        for namespace in namespaces {
            let choices = await accounts?.choices(for: namespace) ?? []
            guard !choices.isEmpty else {
                result.unavailable.insert(namespace)
                continue
            }

            let offered = Set(choices.map(\.account.address))
            let preferred = [await session.activeAccount?.address, await session.grantedAddress(namespace)]
                .compactMap { $0 }
                .first(where: offered.contains)

            selections.append(
                DappAccountSelection(
                    choices: choices, defaultAddress: preferred ?? choices[0].account.address, namespace: namespace
                )
            )
        }

        guard !selections.isEmpty else {
            return result
        }

        let approving = approving
        let chosen = await session.withExclusiveApproval {
            await approving.chooseAccounts(origin: origin, selections: selections)
        }

        guard let chosen else {
            result.isRejected = true
            return result
        }

        for selection in selections where chosen[selection.namespace] == nil {
            result.declined.insert(selection.namespace)
        }

        for (namespace, account) in chosen {
            if await session.grantConnection(namespace, origin: origin, account: account) {
                result.accounts[namespace] = account
            }
        }

        await selectActiveAccount(from: result.accounts, order: namespaces)
        return result
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
