//
//  HyperliquidPlugin.swift
//  Reefr Wallet
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation
import WalletKit

/// A HyperEVM account's HyperCore Portfolio Value and Unrealized PnL. See ADR-074.
struct HyperliquidPlugin: DefiPlugin {
    static let kind = DefiPluginKind.hyperliquid
    /// Perp dexes queried per run (2 weight each); more leave both metrics partial.
    static let maxDexes = 32

    let account: Account

    private let client: any HyperliquidInfoClient
    private let databaseService: DatabaseService
    private let metadata: HyperliquidMetadataCache

    init(account: Account) {
        self.init(account: account, databaseService: DI.injectOrFail(DatabaseService.self))
    }

    init(
        account: Account,
        databaseService: DatabaseService,
        client: any HyperliquidInfoClient = LiveHyperliquidInfoClient.shared,
        metadata: HyperliquidMetadataCache = .shared
    ) {
        self.account = account
        self.client = client
        self.databaseService = databaseService
        self.metadata = metadata
    }

    static func isSupported(_ blockchain: Blockchain) -> Bool {
        network(blockchain) != nil
    }

    static func network(_ blockchain: Blockchain) -> HyperliquidNetwork? {
        guard case let .evm(.hyperEVM(network)) = blockchain else {
            return nil
        }

        return network == .mainnet ? .mainnet : .testnet
    }

    func refresh() async throws {
        let stored = try await databaseService.fetchDefiPositions(account: account, kind: Self.kind)
        let outcomes = try await outcomes(isStored: stored.contains { $0.key == HyperliquidPosition.recordKey })
        try await databaseService.saveDefiOutcomes(account: account, kind: Self.kind, outcomes)
    }

    // MARK: - Fetch

    /// The account's single record, or its removal when there's nothing to show.
    func outcomes(isStored: Bool) async throws -> [DefiPositionOutcome] {
        guard let network = Self.network(account.blockchain) else {
            return []
        }

        let user = account.address.lowercased()
        let client = client
        let metadata = try await metadata.metadata(network, client: client)
        let dexes = Array(metadata.dexes.prefix(Self.maxDexes))

        @Sendable func get<Value: Decodable>(_ request: HyperliquidRequest) async throws -> Value {
            try await client.decoded(request, network: network)
        }

        // The mode is read every run: a switch changes the formula.
        async let mode: String = get(.userAbstraction(user: user))
        async let spot: Hyperliquid.SpotClearinghouseState = get(.spotClearinghouseState(user: user))
        async let borrowLend: Hyperliquid.BorrowLendUserState = get(.borrowLendUserState(user: user))
        async let vaults: [Hyperliquid.VaultEquity] = get(.userVaultEquities(user: user))
        async let stake: Hyperliquid.DelegatorSummary = get(.delegatorSummary(user: user))

        let clearinghouses = try await withThrowingTaskGroup(
            of: (String, Hyperliquid.ClearinghouseState).self
        ) { group in
            for dex in dexes {
                group.addTask {
                    try await (dex, get(.clearinghouseState(user: user, dex: dex)))
                }
            }

            return try await group.reduce(into: [:]) { $0[$1.0] = $1.1 }
        }

        let input = try await HyperliquidValuation.Input(
            borrowLend: borrowLend,
            clearinghouses: clearinghouses,
            mode: mode,
            network: network,
            perpMetas: metadata.perpMetas,
            spot: spot,
            spotMeta: metadata.spot,
            stake: stake,
            unqueriedDexCount: metadata.dexes.count - dexes.count,
            vaults: vaults
        )

        guard let position = HyperliquidValuation.value(input) else {
            return isStored ? [.removed(key: HyperliquidPosition.recordKey)] : []
        }

        return try [.updated(position.record)]
    }
}
