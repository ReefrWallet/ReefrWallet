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

/// One chain a proposal asks for, with the accounts the user may pick.
struct WalletConnectChainChoice: Identifiable {
    let accounts: [Account]
    let blockchain: Blockchain
    let chain: String
    let isRequired: Bool
    var selected: Account?

    var id: String {
        chain
    }
}

/// A proposal waiting for the user's decision.
struct WalletConnectPendingProposal: Identifiable {
    var choices: [WalletConnectChainChoice]
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

    func updateSelection(chain: String, account: Account) {
        guard var pending = pendingProposal, let index = pending.choices.firstIndex(where: { $0.chain == chain }) else {
            return
        }

        pending.choices[index].selected = account
        pendingProposal = pending
    }

    /// The CAIP-2 chains of `choices` grouped by namespace.
    static func namespaces(for choices: [WalletConnectChainChoice]) -> [WalletConnectApprovedNamespace] {
        var grouped: [String: [WalletConnectChainChoice]] = [:]

        for choice in choices where choice.selected != nil {
            grouped[String(choice.chain.prefix { $0 != ":" }), default: []].append(choice)
        }

        return grouped.keys.sorted().compactMap { namespace -> WalletConnectApprovedNamespace? in
            guard
                let chosen = grouped[namespace],
                let dappNamespace = WalletConnectChain.dappNamespace(caip2: chosen[0].chain)
            else {
                return nil
            }

            return WalletConnectApprovedNamespace(
                accounts: chosen.compactMap { choice in
                    choice.selected.map { WalletConnectAccountRef(address: $0.address, chain: choice.chain) }
                },
                chains: chosen.map(\.chain),
                events: WalletConnectChain.events[dappNamespace] ?? [],
                methods: WalletConnectChain.methods[dappNamespace] ?? [],
                namespace: namespace
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
        var choices: [WalletConnectChainChoice] = []

        for chain in proposal.allChains {
            guard let blockchain = WalletConnectChain.blockchain(caip2: chain) else {
                continue
            }

            let candidates = accounts.filter { $0.blockchain == blockchain }
            choices.append(
                WalletConnectChainChoice(
                    accounts: candidates,
                    blockchain: blockchain,
                    chain: chain,
                    isRequired: proposal.requiredChains.contains(chain),
                    selected: candidates.first
                )
            )
        }

        let unsatisfied = proposal.requiredChains.filter { chain in
            !choices.contains { $0.chain == chain && $0.selected != nil }
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
        let result = await result(for: request)

        do {
            try await client.respond(topic: request.topic, requestId: request.id, result: result)
        } catch {
            failureMessage = "Couldn't reply to the dapp: \(error.localizedDescription)"
        }
    }

    private func result(for request: WalletConnectRequest) async -> Result<Data, WalletConnectRPCError> {
        guard request.verification != .scam else {
            return .failure(WalletConnectRequestRouter.rpcError(.unauthorized))
        }

        guard
            let session = sessions.first(where: { $0.topic == request.topic }),
            let approved = session.accounts.first(where: { $0.chain == request.chainId }),
            let blockchain = WalletConnectChain.blockchain(caip2: request.chainId),
            let account = try? await databaseService.fetchAllAccounts()
                .first(where: { $0.address == approved.address && $0.blockchain == blockchain })
        else {
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
