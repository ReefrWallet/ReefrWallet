//
//  WalletConnectModels.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 17.10.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation

/// How the Verify API classified a proposal's or request's origin.
enum WalletConnectVerification: String, Sendable {
    case invalid
    case scam
    case unknown
    case valid
}

/// A dapp's request to open a session, stripped of Reown types.
struct WalletConnectProposal: Identifiable, Sendable {
    let id: String
    let iconURL: URL?
    let name: String
    let optionalChains: [String]
    let requiredChains: [String]
    let url: String
    let verification: WalletConnectVerification

    var allChains: [String] {
        requiredChains + optionalChains.filter { !requiredChains.contains($0) }
    }
}

/// One JSON-RPC request on a session.
struct WalletConnectRequest: Identifiable, Sendable {
    let chainId: String
    let id: String
    let method: String
    /// The raw JSON `params`.
    let params: Data
    let topic: String
    let verification: WalletConnectVerification
}

/// A CAIP-10 account a session was approved with.
struct WalletConnectAccountRef: Hashable, Sendable {
    let address: String
    /// CAIP-2 chain id, e.g. `eip155:1`.
    let chain: String
}

struct WalletConnectSessionInfo: Identifiable, Sendable {
    let accounts: [WalletConnectAccountRef]
    let expiry: Date
    let iconURL: URL?
    let name: String
    let topic: String
    let url: String

    var id: String {
        topic
    }
}

/// What the wallet approves for one CAIP-2 namespace (`eip155`, `solana`, ...).
struct WalletConnectApprovedNamespace: Sendable {
    let accounts: [WalletConnectAccountRef]
    let chains: [String]
    let events: [String]
    let methods: [String]
    let namespace: String
}

enum WalletConnectError: LocalizedError, Equatable {
    case invalidURI
    case noMatchingAccount
    case unavailable
    case unsupportedChain(String)

    var errorDescription: String? {
        switch self {
        case .invalidURI: "That isn't a WalletConnect link."
        case .noMatchingAccount: "No matching account."
        case .unavailable: "WalletConnect isn't available on this platform yet."
        case let .unsupportedChain(chain): "Unsupported network \(chain)."
        }
    }
}

/// The transport to the WalletConnect relay. Implemented over Reown's
/// SDK by ``ReownWalletConnectClient``; faked in tests.
@MainActor
protocol WalletConnectClient: AnyObject {
    var onProposal: ((WalletConnectProposal) -> Void)? { get set }
    var onRequest: ((WalletConnectRequest) -> Void)? { get set }
    var onSessions: (([WalletConnectSessionInfo]) -> Void)? { get set }

    func approve(proposalId: String, namespaces: [WalletConnectApprovedNamespace]) async throws
    func configure()
    func disconnect(topic: String) async throws
    func pair(uri: String) async throws
    func reject(proposalId: String) async throws
    func respond(topic: String, requestId: String, result: Result<Data, WalletConnectRPCError>) async throws
    func sessions() -> [WalletConnectSessionInfo]
}

struct WalletConnectRPCError: Error, Equatable, Sendable {
    let code: Int
    let message: String
}
