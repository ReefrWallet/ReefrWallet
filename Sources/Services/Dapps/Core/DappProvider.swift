//
//  DappProvider.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 25.09.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

/// The origin, session, and services a ``DappProvider`` needs to answer
/// one request.
struct DappRequestContext: Sendable {
    let origin: String
    let session: DappSession
    let approving: any DappApproving
    let signingService: DappSigningService
}

extension DappRequestContext {
    /// Re-validates the origin, account and permission captured when the
    /// request began; call after approval, right before signing.
    func authorize(_ namespace: DappNamespace, account: Account) async throws(DappError) {
        try await session.authorize(namespace, origin: origin, account: account)
    }
}

/// One `window.__reefr._emit(namespace, event, payload)` push to the page
/// — `accountsChanged`, `chainChanged`, `disconnect`, ....
struct DappEvent: Sendable {
    let name: String
    let payload: JSONValue
}

/// A wallet-provider namespace's request handler — the seam each chain
/// (``EthereumDappProvider`` today) plugs into the chain-agnostic
/// ``DappBridge``/``DappSession``/``DappApproving`` machinery through.
/// Adding a chain means one conformer here, one JS provider file, and one
/// approval-detail view — the bridge, session, and window aren't touched.
protocol DappProvider: Sendable {
    /// The namespace this provider answers requests for.
    static var namespace: DappNamespace { get }

    /// Handles one JSON-RPC-shaped request from the page.
    func handle(method: String, params: JSONValue, context: DappRequestContext) async throws(DappError) -> JSONValue

    /// The events this provider should emit in reaction to `session`'s
    /// current state — e.g. the user switching the connected account in
    /// the browser's account picker, or the origin changing.
    func sessionDidChange(_ session: DappSessionSnapshot) -> [DappEvent]

    /// Maps `error` onto this namespace's wire format (EIP-1193's numeric
    /// codes for Ethereum; CIP-30's `APIError`/`TxSignError` for Cardano).
    func wireError(_ error: DappError) -> JSONValue
}
