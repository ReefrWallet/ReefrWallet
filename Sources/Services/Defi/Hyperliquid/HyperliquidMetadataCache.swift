//
//  HyperliquidMetadataCache.swift
//  Reefr Wallet
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation

/// Network-wide `/info` metadata shared by every account's run for a short
/// while, so per-account runs spend weight only on user state. See ADR-074.
actor HyperliquidMetadataCache {
    struct Metadata: Sendable {
        let dexes: [String]
        let fetchedAt: Date
        let perpMetas: [Hyperliquid.PerpMeta]
        let spot: Hyperliquid.SpotMetaAndAssetCtxs
    }

    static let maxAge: TimeInterval = 60
    static let shared = HyperliquidMetadataCache()

    private var entries: [HyperliquidNetwork: Metadata] = [:]
    private var inFlight: [HyperliquidNetwork: Task<Metadata, any Error>] = [:]

    func metadata(
        _ network: HyperliquidNetwork,
        client: any HyperliquidInfoClient,
        now: Date = .now
    ) async throws -> Metadata {
        if let entry = entries[network], now.timeIntervalSince(entry.fetchedAt) < Self.maxAge {
            return entry
        }

        if let task = inFlight[network] {
            return try await task.value
        }

        let task = Task {
            async let dexes: [Hyperliquid.PerpDex?] = client.decoded(.perpDexs, network: network)
            async let perpMetas: [Hyperliquid.PerpMeta] = client.decoded(.allPerpMetas, network: network)
            async let spot: Hyperliquid.SpotMetaAndAssetCtxs = client.decoded(.spotMetaAndAssetCtxs, network: network)

            // The first dex is `null` in `perpDexs` and `""` in requests.
            return try await Metadata(
                dexes: [""] + dexes.dropFirst().compactMap { $0?.name },
                fetchedAt: now,
                perpMetas: perpMetas,
                spot: spot
            )
        }

        inFlight[network] = task
        defer { inFlight[network] = nil }

        let metadata = try await task.value
        entries[network] = metadata
        return metadata
    }
}
