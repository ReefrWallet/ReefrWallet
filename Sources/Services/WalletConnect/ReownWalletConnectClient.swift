//
//  ReownWalletConnectClient.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 17.10.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

// The only file that imports Reown's SDK: its `Account` and `Blockchain`
// names would clash with Reefr's own WalletKit types. Uses Reown's Sign
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
            socketFactory: URLSessionSocketFactory()
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

        subscribe()
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

    func subscribe() {
        Sign.instance.sessionProposalPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] proposal, context in
                MainActor.assumeIsolated {
                    self?.onProposal?(
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
            }
            .store(in: &cancellables)

        Sign.instance.sessionRequestPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] request, context in
                guard
                    let id = (try? JSONEncoder().encode(request.id)).flatMap({ String(data: $0, encoding: .utf8) }),
                    let params = try? JSONEncoder().encode(request.params)
                else {
                    Logger.verbose("WC request dropped: id or params not encodable, method: \(request.method)")
                    return
                }

                Logger.verbose(
                    "WC request received: \(request.method) id: \(id) chain: \(request.chainId.absoluteString) "
                        + "topic: \(request.topic.prefix(8)) params: \(String(data: params, encoding: .utf8) ?? "")"
                )

                MainActor.assumeIsolated {
                    self?.onRequest?(
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
            }
            .store(in: &cancellables)

        Sign.instance.sessionsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                MainActor.assumeIsolated {
                    self?.onSessions?(sessions.map(Self.info(for:)))
                }
            }
            .store(in: &cancellables)
    }
}

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

// MARK: - Sockets

private struct URLSessionSocketFactory: WebSocketFactory {
    func create(with url: URL) -> WebSocketConnecting {
        URLSessionWebSocket(url: url)
    }
}

private final class URLSessionWebSocket: NSObject, WebSocketConnecting, URLSessionWebSocketDelegate,
    @unchecked Sendable {
    var isConnected = false
    var onConnect: (() -> Void)?
    var onDisconnect: ((Error?) -> Void)?
    var onText: ((String) -> Void)?
    var request: URLRequest

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?

    init(url: URL) {
        request = URLRequest(url: url)
        super.init()
    }

    func connect() {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        self.session = session
        task = session.webSocketTask(with: request)
        task?.resume()
        receive()
    }

    func disconnect() {
        task?.cancel(with: .normalClosure, reason: nil)
        isConnected = false
    }

    func write(string: String, completion: (() -> Void)?) {
        task?.send(.string(string)) { _ in completion?() }
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else {
                return
            }

            switch result {
            case let .success(message):
                if case let .string(text) = message {
                    onText?(text)
                }

                receive()
            case let .failure(error):
                isConnected = false
                onDisconnect?(error)
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        isConnected = true
        onConnect?()
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        isConnected = false
        onDisconnect?(nil)
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
