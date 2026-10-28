//
//  WalletConnectService.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 17.10.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation
import Observation
import SwiftData
import WalletKit

/// A chain a proposal asks for.
struct WalletConnectProposedChain: Identifiable {
    let blockchain: Blockchain
    let chain: String
    let isRequired: Bool

    var id: String {
        chain
    }
}

/// One namespace a proposal asks for. A single account is picked as the
/// default for all of its chains, as WalletConnect does.
struct WalletConnectNamespaceChoice: Identifiable {
    let accounts: [Account]
    let chains: [WalletConnectProposedChain]
    let keyNames: [PersistentIdentifier: String]
    let namespace: String
    var selected: Account?

    var id: String {
        namespace
    }

    /// `"<key> · <account> (<shortened address>)"`, as in the browser's account drop-down.
    func label(for account: Account) -> String {
        DappAccountChoice(account: account, keyStoreName: keyNames[account.keyStoreId] ?? "").label
    }
}

/// A proposal waiting for the user's decision.
struct WalletConnectPendingProposal: Identifiable {
    var choices: [WalletConnectNamespaceChoice]
    let proposal: WalletConnectProposal

    var id: String {
        proposal.id
    }
}

/// App-wide WalletConnect state: pairing, proposals, requests and the
/// live sessions mirrored into the sidebar (ADR-035).
@MainActor
@Observable
final class WalletConnectService {
    let approver: DappApprover

    var failureMessage: String?
    private(set) var pendingProposal: WalletConnectPendingProposal?
    private(set) var sessions: [WalletConnectSessionInfo] = []

    @ObservationIgnored private let client: any WalletConnectClient
    @ObservationIgnored private var dappSessions: [String: DappSession] = [:]
    @ObservationIgnored private let databaseService: DatabaseService
    @ObservationIgnored private var queuedProposals: [WalletConnectProposal] = []
    @ObservationIgnored private let router: WalletConnectRequestRouter

    init(
        client: (any WalletConnectClient)? = nil,
        databaseService: DatabaseService? = nil,
        signingService: DappSigningService? = nil
    ) {
        let approver = DappApprover()
        self.approver = approver
        self.client = client ?? makeWalletConnectClient()
        self.databaseService = databaseService ?? DI.injectOrFail(DatabaseService.self)
        router = WalletConnectRequestRouter(
            approving: approver, signingService: signingService ?? DI.injectOrFail(DappSigningService.self)
        )
    }

    /// Starts the relay connection and restores persisted sessions.
    func start() {
        client.onProposal = { [weak self] proposal in
            self?.enqueue(proposal)
        }

        client.onRequest = { [weak self] request in
            guard let self else {
                return
            }

            Task { await self.handle(request) }
        }

        client.onSessions = { [weak self] sessions in
            self?.update(sessions)
        }

        client.configure()
        update(client.sessions())
    }

    // MARK: Pairing

    /// Pairs from a `wc:` URI or a `reefr://wc?uri=...` deep link.
    func pair(uri: String) async {
        do {
            try await client.pair(uri: Self.pairingURI(from: uri))
        } catch {
            failureMessage = "Couldn't connect: \(error.localizedDescription)"
        }
    }

    func disconnect(topic: String) async {
        do {
            try await client.disconnect(topic: topic)
        } catch {
            failureMessage = "Couldn't disconnect: \(error.localizedDescription)"
        }

        dappSessions[topic] = nil
        update(sessions.filter { $0.topic != topic })
    }

    /// Disconnects every session approved with any of `addresses`.
    func disconnectSessions(addresses: Set<String>) async {
        let topics = sessions
            .filter { session in session.accounts.contains { addresses.contains($0.address) } }
            .map(\.topic)

        for topic in topics {
            await disconnect(topic: topic)
        }
    }

    nonisolated static func pairingURI(from string: String) -> String {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)

        guard
            trimmed.hasPrefix("reefr:"),
            let components = URLComponents(string: trimmed),
            let uri = components.queryItems?.first(where: { $0.name == "uri" })?.value
        else {
            return trimmed
        }

        return uri
    }

    // MARK: Proposals

    func approveProposal(selection: WalletConnectPendingProposal) async {
        let namespaces = Self.namespaces(for: selection.choices)
        pendingProposal = nil

        do {
            try await client.approve(proposalId: selection.proposal.id, namespaces: namespaces)
        } catch {
            failureMessage = "Couldn't connect: \(error.localizedDescription)"
        }

        presentNextProposal()
    }

    func rejectProposal() async {
        guard let proposal = pendingProposal?.proposal else {
            return
        }

        pendingProposal = nil
        try? await client.reject(proposalId: proposal.id)
        presentNextProposal()
    }

    func updateSelection(namespace: String, account: Account) {
        guard
            var pending = pendingProposal,
            let index = pending.choices.firstIndex(where: { $0.namespace == namespace })
        else {
            return
        }

        pending.choices[index].selected = account
        pendingProposal = pending
    }

    /// One approved namespace per choice, giving the selected account on every chain.
    static func namespaces(for choices: [WalletConnectNamespaceChoice]) -> [WalletConnectApprovedNamespace] {
        choices.sorted { $0.namespace < $1.namespace }.compactMap { choice -> WalletConnectApprovedNamespace? in
            guard
                let account = choice.selected,
                let first = choice.chains.first,
                let dappNamespace = WalletConnectChain.dappNamespace(caip2: first.chain)
            else {
                return nil
            }

            return WalletConnectApprovedNamespace(
                accounts: choice.chains.map { WalletConnectAccountRef(address: account.address, chain: $0.chain) },
                chains: choice.chains.map(\.chain),
                events: WalletConnectChain.events[dappNamespace] ?? [],
                methods: WalletConnectChain.methods[dappNamespace] ?? [],
                namespace: choice.namespace
            )
        }
    }

    // MARK: Private

    private func enqueue(_ proposal: WalletConnectProposal) {
        guard pendingProposal != nil else {
            Task { await present(proposal) }
            return
        }

        queuedProposals.append(proposal)
    }

    private func presentNextProposal() {
        guard !queuedProposals.isEmpty else {
            return
        }

        let next = queuedProposals.removeFirst()
        Task { await present(next) }
    }

    private func present(_ proposal: WalletConnectProposal) async {
        if proposal.verification == .scam {
            try? await client.reject(proposalId: proposal.id)
            failureMessage = "\(proposal.name) was blocked: it's flagged as malicious."
            presentNextProposal()
            return
        }

        let accounts = await signingAccounts()
        var chainsByNamespace: [String: [WalletConnectProposedChain]] = [:]

        for chain in proposal.allChains {
            guard let blockchain = WalletConnectChain.blockchain(caip2: chain) else {
                continue
            }

            chainsByNamespace[String(chain.prefix { $0 != ":" }), default: []].append(
                WalletConnectProposedChain(
                    blockchain: blockchain, chain: chain, isRequired: proposal.requiredChains.contains(chain)
                )
            )
        }

        var keyNames: [PersistentIdentifier: String] = [:]
        for account in accounts where keyNames[account.keyStoreId] == nil {
            keyNames[account.keyStoreId] = (try? await databaseService.fetchKeyStore(id: account.keyStoreId))?.name
        }

        let choices = chainsByNamespace.keys.sorted().map { namespace -> WalletConnectNamespaceChoice in
            let chains = chainsByNamespace[namespace] ?? []
            var seen: Set<String> = []
            let candidates = accounts.filter { account in
                chains.contains {
                    WalletConnectChain.dappNamespace(caip2: $0.chain)?.matches(account.blockchain) == true
                } && seen.insert("\(account.keyStoreId.hashValue)/\(account.address)").inserted
            }

            return WalletConnectNamespaceChoice(
                accounts: candidates,
                chains: chains,
                keyNames: keyNames,
                namespace: namespace,
                selected: candidates.first
            )
        }

        let unsatisfied = choices.filter { choice in
            choice.selected == nil && choice.chains.contains(where: \.isRequired)
        }

        guard unsatisfied.isEmpty else {
            try? await client.reject(proposalId: proposal.id)
            failureMessage = "\(proposal.name) needs networks or accounts this wallet doesn't have."
            presentNextProposal()
            return
        }

        pendingProposal = WalletConnectPendingProposal(choices: choices, proposal: proposal)
    }

    private func signingAccounts() async -> [Account] {
        guard let all = try? await databaseService.fetchAllAccounts() else {
            return []
        }

        var result: [Account] = []
        var watchOnly: [PersistentIdentifier: Bool] = [:]

        for account in all {
            let key = account.keyStoreId
            if watchOnly[key] == nil {
                let keyStore = try? await databaseService.fetchKeyStore(id: account.keyStoreId)
                watchOnly[key] = keyStore?.kind == .watchOnly
            }

            if watchOnly[key] == false {
                result.append(account)
            }
        }

        return result
    }

    private func update(_ sessions: [WalletConnectSessionInfo]) {
        self.sessions = sessions
    }

    private func dappSession(for session: WalletConnectSessionInfo) -> DappSession {
        if let existing = dappSessions[session.topic] {
            return existing
        }

        let created = DappSession(origin: session.url)
        dappSessions[session.topic] = created
        return created
    }

    private func handle(_ request: WalletConnectRequest) async {
        Logger.verbose("WC handle start: \(request.method) id: \(request.id)")
        let result = await result(for: request)
        Logger.verbose("WC handle done: \(request.method) id: \(request.id) ok: \((try? result.get()) != nil)")

        do {
            try await client.respond(topic: request.topic, requestId: request.id, result: result)
        } catch {
            Logger.verbose("WC handle respond threw: \(error)")
            failureMessage = "Couldn't reply to the dapp: \(error.localizedDescription)"
        }
    }

    private func result(for request: WalletConnectRequest) async -> Result<Data, WalletConnectRPCError> {
        guard request.verification != .scam else {
            Logger.verbose("WC request refused: verification is scam")
            return .failure(WalletConnectRequestRouter.rpcError(.unauthorized))
        }

        guard
            let session = sessions.first(where: { $0.topic == request.topic }),
            let approved = session.accounts.first(where: { $0.chain == request.chainId }),
            let blockchain = WalletConnectChain.blockchain(caip2: request.chainId),
            let all = try? await databaseService.fetchAllAccounts(),
            let account = all.first(where: { $0.address == approved.address && $0.blockchain == blockchain })
                ?? all.first(where: {
                    $0.address == approved.address
                        && WalletConnectChain.dappNamespace(caip2: request.chainId)?.matches($0.blockchain) == true
                })
        else {
            Logger.verbose(
                "WC request unauthorized: no session/account for topic \(request.topic.prefix(8)) chain \(request.chainId); "
                    + "sessions: \(sessions.count)"
            )
            return .failure(WalletConnectRequestRouter.rpcError(.unauthorized))
        }

        return await router.handle(
            method: request.method,
            params: request.params,
            chainId: request.chainId,
            account: account,
            origin: session.url,
            session: dappSession(for: session)
        )
    }
}
