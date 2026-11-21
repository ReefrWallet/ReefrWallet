//
//  TonJettonScanner.swift
//  Reefr Wallet
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation
import WalletKit

/// Reads an account's TON Jetton transfers apart from its wallet's own history (ADR-071): a Jetton wallet can be
/// credited with no transaction on the owner wallet, so the owner wallet's cursor cannot see it.
///
/// A backward scan fixes its upper bound, so pages don't shift as newer actions arrive. Once it finishes, a forward
/// watermark follows; every forward pass re-reads an overlapping range, and the caller deduplicates by action id,
/// so an action that becomes visible late inside the overlap is still picked up.
struct TonJettonScanner {
    /// The backward scan in progress.
    struct Backfill: Codable, Equatable {
        /// The provider's cursor for the next page. While `endLt` is `nil` the scan is still looking for the newest
        /// readable action, and the cursor is the probe's.
        var cursor: String?
        /// The fixed upper bound (a trace end lt), once known.
        var endLt: UInt64?
    }

    /// The forward scan in progress.
    struct Scan: Codable, Equatable {
        var cursor: String?
        var highest: UInt64
        var startLt: UInt64
    }

    /// The state once the backfill is done.
    struct Forward: Codable, Equatable {
        var scan: Scan?
        var watermark: UInt64
    }

    /// What one pass read, and the progress to store with it.
    struct Step: Equatable {
        var actions: [TonJettonAction]
        var backfill: Backfill?
        var forward: Forward?
    }

    typealias Fetch = (
        _ ascending: Bool,
        _ startLt: UInt64?,
        _ endLt: UInt64?,
        _ limit: Int,
        _ cursor: String?
    ) async throws -> TonJettonPage

    /// Trace logical times advance by about a million per block; this re-reads roughly a hundred blocks.
    static let overlap: UInt64 = 100_000_000
    static let pageSize = 50
    /// Pages read per pass, so one pass stays short; the rest follows on the next.
    static let pagesPerPass = 10

    let fetch: Fetch

    /// One bounded pass from the stored progress (both `nil` for an account not scanned yet).
    func step(backfill: Backfill?, forward: Forward?) async throws -> Step {
        if let backfill {
            return try await continueBackfill(backfill)
        }

        if let forward {
            return try await continueForward(forward)
        }

        return try await continueBackfill(Backfill(cursor: nil, endLt: nil))
    }

    private func continueBackfill(_ start: Backfill) async throws -> Step {
        var backfill = start

        if backfill.endLt == nil {
            // The newest readable action fixes the bound; unreadable ones are skipped by following the cursor.
            for _ in 0 ..< Self.pagesPerPass {
                let page = try await fetch(false, nil, nil, Self.pageSize, backfill.cursor)

                if let newest = page.actions.map(\.lt).max() {
                    backfill = Backfill(cursor: nil, endLt: newest)
                    break
                }

                guard let next = page.nextCursor else {
                    return Step(actions: [], backfill: nil, forward: Forward(scan: nil, watermark: 0))
                }

                backfill.cursor = next
            }

            // Nothing readable within this pass: keep the probe's place for the next one.
            guard backfill.endLt != nil else {
                return Step(actions: [], backfill: backfill, forward: nil)
            }
        }

        var actions: [TonJettonAction] = []

        let bound = backfill.endLt
        for _ in 0 ..< Self.pagesPerPass {
            let page = try await fetch(false, nil, bound, Self.pageSize, backfill.cursor)
            actions += page.actions

            // The provider decides when the history ends; a page with unreadable actions can be short.
            guard let next = page.nextCursor else {
                return Step(actions: actions, backfill: nil, forward: Forward(scan: nil, watermark: bound ?? 0))
            }

            backfill.cursor = next
        }

        return Step(actions: actions, backfill: backfill, forward: nil)
    }

    private func continueForward(_ start: Forward) async throws -> Step {
        var forward = start
        var scan = start.scan ?? Scan(
            cursor: nil,
            highest: start.watermark,
            startLt: start.watermark > Self.overlap ? start.watermark - Self.overlap : 0
        )

        var actions: [TonJettonAction] = []

        for _ in 0 ..< Self.pagesPerPass {
            let page = try await fetch(true, scan.startLt, nil, Self.pageSize, scan.cursor)
            actions += page.actions
            scan.highest = max(scan.highest, page.actions.map(\.lt).max() ?? 0)

            guard let next = page.nextCursor else {
                forward.watermark = scan.highest
                forward.scan = nil
                return Step(actions: actions, backfill: nil, forward: forward)
            }

            scan.cursor = next
        }

        forward.scan = scan
        return Step(actions: actions, backfill: nil, forward: forward)
    }
}
