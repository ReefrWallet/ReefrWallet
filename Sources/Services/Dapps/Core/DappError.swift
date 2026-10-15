//
//  DappError.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 25.09.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

/// A chain-agnostic dapp-request failure. Each ``DappProvider`` maps its
/// own cases (plus this shared set) onto its wire format —
/// ``EthereumDappProvider`` uses EIP-1193's numeric codes (4001, 4100,
/// 4200, 4900, 4902, -32602, -32603) via `wireError(_:)`; CIP-30's
/// `APIError`/`TxSignError` will do the same for Cardano later.
enum DappError: Swift.Error, Sendable {
    /// The user rejected the request (declined a connect/sign/send prompt).
    case userRejected

    /// The origin isn't permitted for the namespace/account it's asking
    /// to use.
    case unauthorized

    /// The requested method isn't implemented by this provider.
    case unsupportedMethod

    /// `params` didn't match what the method expects. `reason` describes
    /// what went wrong.
    case invalidParams(String)

    /// The session has no connected account for this namespace.
    case disconnected

    /// A chain-switch request named a chain this wallet has no account
    /// for.
    case chainNotFound

    /// An unexpected internal failure. `reason` carries diagnostic
    /// detail; this case shouldn't normally surface from correct usage.
    case internalError(String)
}
