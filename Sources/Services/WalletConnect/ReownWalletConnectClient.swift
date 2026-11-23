//
//  ReownWalletConnectClient.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 17.10.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

// With `ReownRelaySocket.swift`, the only file that imports Reown's SDK: its
// `Account` and `Blockchain` names would clash with Reefr's own WalletKit types. Uses Reown's Sign
// SDK directly: `ReownWalletKit` needs Yttrium, which has no macOS slice.
import Foundation

#if canImport(WalletConnectSign)

import Combine
import WalletConnectNetworking
import WalletConnectSign
import WalletConnectUtils

@MainActor
final class ReownWalletConnectClient: WalletConnectClient {
    var onProposal: ((WalletConnectProposal) -> Void)?
    var onRequest: ((WalletConnectRequest) -> Void)?
    var onSessions: (([WalletConnectSessionInfo]) -> Void)?

    private var cancellables: Set<AnyCancellable> = []
    private var isConfigured = false
#if os(macOS)
    private var isSocketConnected = false
    private var reconnectTask: Task<Void, Never>?
#endif

    func approve(proposalId: String, namespaces: [WalletConnectApprovedNamespace]) async throws {
        var sessionNamespaces: [String: SessionNamespace] = [:]

        for namespace in namespaces {
            sessionNamespaces[namespace.namespace] = SessionNamespace(
                chains: namespace.chains.compactMap { Blockchain($0) },
                accounts: namespace.accounts.compactMap { WalletConnectUtils.Account("\($0.chain):\($0.address)") },
                methods: Set(namespace.methods),
                events: Set(namespace.events)
            )
        }

        _ = try await Sign.instance.approve(proposalId: proposalId, namespaces: sessionNamespaces)
    }

    func configure() {
        guard !isConfigured else {
            return
        }

        isConfigured = true

        Networking.configure(
            groupIdentifier: WalletConnectConfig.groupIdentifier,
            projectId: WalletConnectConfig.projectId,
            socketFactory: ReownRelaySocketFactory()
        )

        // Native-only redirect never throws (no universal link / link mode).
        // swiftlint:disable:next force_try
        let redirect = try! AppMetadata.Redirect(native: WalletConnectConfig.redirectScheme, universal: nil)
        let metadata = AppMetadata(
            name: WalletConnectConfig.appName,
            description: WalletConnectConfig.appDescription,
            url: WalletConnectConfig.appURL,
            icons: [WalletConnectConfig.appIconURL],
            redirect: redirect
        )

        Pair.configure(metadata: metadata)
        Sign.configure(crypto: UnsupportedCryptoProvider())

        if Logger.isVerbose {
            Networking.instance.setLogging(level: .debug)
            Relay.instance.setLogging(level: .debug)
            Sign.instance.setLogging(level: .debug)
        }

        subscribe()
        observeConnection()
    }

    func disconnect(topic: String) async throws {
        try await Sign.instance.disconnect(topic: topic)
    }

    func pair(uri: String) async throws {
        guard let uri = try? WalletConnectURI(uriString: uri) else {
            throw WalletConnectError.invalidURI
        }

        try await Pair.instance.pair(uri: uri)
    }

    func reject(proposalId: String) async throws {
        try await Sign.instance.rejectSession(proposalId: proposalId, reason: .userRejected)
    }

    func respond(topic: String, requestId: String, result: Result<Data, WalletConnectRPCError>) async throws {
        let id = try JSONDecoder().decode(RPCID.self, from: Data(requestId.utf8))
        let response: RPCResult

        switch result {
        case let .success(data):
            Logger.verbose("WC respond success id: \(requestId) result: \(String(data: data, encoding: .utf8) ?? "")")
            response = .response(try JSONDecoder().decode(AnyCodable.self, from: data))
        case let .failure(error):
            Logger.verbose("WC respond error id: \(requestId) code: \(error.code) message: \(error.message)")
            response = .error(JSONRPCError(code: error.code, message: error.message))
        }

        do {
            try await Sign.instance.respond(topic: topic, requestId: id, response: response)
            Logger.verbose("WC respond delivered id: \(requestId)")
        } catch {
            Logger.verbose("WC respond failed id: \(requestId) error: \(error)")
            throw error
        }
    }

    func sessions() -> [WalletConnectSessionInfo] {
        isConfigured ? Sign.instance.getSessions().map(Self.info(for:)) : []
    }
}

// MARK: - Mapping

private extension ReownWalletConnectClient {
    static func chains(_ namespaces: [String: ProposalNamespace]?) -> [String] {
        (namespaces ?? [:]).sorted { $0.key < $1.key }.flatMap { key, namespace in
            namespace.chains?.map(\.absoluteString) ?? (key.contains(":") ? [key] : [])
        }
    }

    static func info(for session: Session) -> WalletConnectSessionInfo {
        WalletConnectSessionInfo(
            accounts: session.accounts.map {
                WalletConnectAccountRef(address: $0.address, chain: $0.blockchain.absoluteString)
            },
            expiry: session.expiryDate,
            iconURL: session.peer.icons.first.flatMap { URL(string: $0) },
            name: session.peer.name,
            topic: session.topic,
            url: session.peer.url
        )
    }

    static func verification(_ context: VerifyContext?) -> WalletConnectVerification {
        switch context?.validation {
        case .invalid: .invalid
        case .scam: .scam
        case .valid: .valid
        case .unknown, nil: .unknown
        }
    }

    func emit(proposal: Session.Proposal, context: VerifyContext?) {
        Logger.verbose("WC proposal: \(proposal.proposer.name) id: \(proposal.id)")

        onProposal?(
            WalletConnectProposal(
                id: proposal.id,
                iconURL: proposal.proposer.icons.first.flatMap { URL(string: $0) },
                name: proposal.proposer.name,
                optionalChains: Self.chains(proposal.optionalNamespaces),
                requiredChains: Self.chains(proposal.requiredNamespaces),
                url: proposal.proposer.url,
                verification: Self.verification(context)
            )
        )
    }

    func emit(request: Request, context: VerifyContext?) {
        guard
            let id = (try? JSONEncoder().encode(request.id)).flatMap({ String(data: $0, encoding: .utf8) }),
            let params = try? JSONEncoder().encode(request.params)
        else {
            // Reown holds back later requests until this one is answered.
            Logger.verbose("WC request refused: id or params not encodable, method: \(request.method)")
            Task {
                try? await Sign.instance.respond(
                    topic: request.topic,
                    requestId: request.id,
                    response: .error(JSONRPCError(code: -32602, message: "Invalid params"))
                )
            }

            return
        }

        Logger.verbose(
            "WC request received: \(request.method) id: \(id) chain: \(request.chainId.absoluteString) "
                + "topic: \(request.topic.prefix(8)) params: \(String(data: params, encoding: .utf8) ?? "")"
        )

        onRequest?(
            WalletConnectRequest(
                chainId: request.chainId.absoluteString,
                id: id,
                method: request.method,
                params: params,
                topic: request.topic,
                verification: Self.verification(context)
            )
        )
    }

    func observeConnection() {
        Relay.instance.socketConnectionStatusPublisher
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                MainActor.assumeIsolated {
                    self?.socketStatusChanged(status)
                }
            }
            .store(in: &cancellables)
    }

    func socketStatusChanged(_ status: SocketConnectionStatus) {
        Logger.verbose("WC relay socket: \(status)")

#if os(macOS)
        isSocketConnected = status == .connected

        if !isSocketConnected {
            reconnect()
        }
#endif
    }

    func subscribe() {
        Sign.instance.sessionProposalPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] proposal, context in
                MainActor.assumeIsolated {
                    self?.emit(proposal: proposal, context: context)
                }
            }
            .store(in: &cancellables)

        Sign.instance.sessionRequestPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] request, context in
                MainActor.assumeIsolated {
                    self?.emit(request: request, context: context)
                }
            }
            .store(in: &cancellables)

        Sign.instance.sessionsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                Logger.verbose("WC sessions: \(sessions.map { "\($0.peer.name) \($0.topic.prefix(8))" })")

                MainActor.assumeIsolated {
                    self?.onSessions?(sessions.map(Self.info(for:)))
                }
            }
            .store(in: &cancellables)
    }
}

#if os(macOS)

// MARK: - Reconnecting

private extension ReownWalletConnectClient {
    /// Reown reconnects a dropped socket only while the app is frontmost on macOS
    /// (`AppStateObserver`), so one that drops while the dApp's browser is in front stays
    /// down. Subscribing to the session and pairing topics makes it connect.
    func reconnect() {
        guard reconnectTask == nil else {
            return
        }

        reconnectTask = Task { [weak self] in
            var delay = 2.0

            while true {
                try? await Task.sleep(for: .seconds(delay))

                guard
                    let self,
                    !self.isSocketConnected,
                    await self.resubscribe()
                else {
                    break
                }

                delay = min(delay * 2, 60)
            }

            self?.reconnectTask = nil
        }
    }

    /// Returns `false` when there's nothing to subscribe to.
    func resubscribe() async -> Bool {
        let now = Date()
        let topics = Sign.instance.getSessions().map(\.topic)
            + Pair.instance.getPairings().filter { $0.expiryDate > now }.map(\.topic)

        guard !topics.isEmpty else {
            Logger.verbose("WC reconnect skipped: no sessions or pairings")
            return false
        }

        Logger.verbose("WC reconnecting: subscribing to \(topics.count) topics")

        do {
            try await Networking.interactor.batchSubscribe(topics: topics)
        } catch {
            Logger.verbose("WC reconnect failed: \(error)")
        }

        return true
    }
}

#endif

// MARK: - Crypto

/// Reown needs this only for SIWE/session-authenticate, which Reefr
/// doesn't offer; proposals, requests and sessions never call it.
private struct UnsupportedCryptoProvider: CryptoProvider {
    private enum Failure: Error {
        case unsupported
    }

    func keccak256(_ data: Data) -> Data {
        preconditionFailure("keccak256 is unavailable: authenticate requests aren't supported")
    }

    func recoverPubKey(signature: EthereumSignature, message: Data) throws -> Data {
        throw Failure.unsupported
    }
}

@MainActor
func makeWalletConnectClient() -> any WalletConnectClient {
    ReownWalletConnectClient()
}

#else

/// Reown's Sign SDK doesn't build for macOS yet (see ADR-035), so Mac
/// builds pair nothing and show no sessions.
@MainActor
final class UnavailableWalletConnectClient: WalletConnectClient {
    var onProposal: ((WalletConnectProposal) -> Void)?
    var onRequest: ((WalletConnectRequest) -> Void)?
    var onSessions: (([WalletConnectSessionInfo]) -> Void)?

    func approve(proposalId: String, namespaces: [WalletConnectApprovedNamespace]) async throws {}

    func configure() {}

    func disconnect(topic: String) async throws {}

    func pair(uri: String) async throws {
        throw WalletConnectError.unavailable
    }

    func reject(proposalId: String) async throws {}

    func respond(topic: String, requestId: String, result: Result<Data, WalletConnectRPCError>) async throws {}

    func sessions() -> [WalletConnectSessionInfo] {
        []
    }
}

@MainActor
func makeWalletConnectClient() -> any WalletConnectClient {
    UnavailableWalletConnectClient()
}

#endif
