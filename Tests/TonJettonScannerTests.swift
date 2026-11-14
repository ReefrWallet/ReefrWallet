// The Jetton scan covers every action exactly once, resumes mid-scan, and picks up an action that becomes visible
// late inside the forward overlap (ADR-071).

import BigInt
import Foundation
import Testing
import WalletKit
@testable import ReefrWallet

struct TonJettonScannerTests {
    private let owner: TonAddress
    private let master: TonAddress

    init() throws {
        owner = try TonAddress(workchain: 0, hash: Data(repeating: 1, count: 32))
        master = try TonAddress(workchain: 0, hash: Data(repeating: 2, count: 32))
    }

    private func action(_ lt: UInt64) -> TonJettonAction {
        TonJettonAction(
            actionId: String(lt, radix: 16),
            amount: 1,
            lt: lt,
            master: master,
            receiver: owner,
            sender: master,
            traceId: "t"
        )
    }

    /// An indexer holding `actions`, honoring the bounds, order and cursor like toncenter: the cursor is opaque
    /// and absent on the last page. Actions in `unreadable` count on the wire but are dropped from the page, as
    /// WalletKit drops an action it can't decode.
    private final class Indexer: @unchecked Sendable {
        var actions: [TonJettonAction]
        var unreadable: Set<String> = []

        init(_ actions: [TonJettonAction]) {
            self.actions = actions
        }

        func fetch(
            ascending: Bool,
            startLt: UInt64?,
            endLt: UInt64?,
            limit: Int,
            cursor: String?
        ) -> TonJettonPage {
            let matching = actions
                .filter { $0.lt >= (startLt ?? 0) && $0.lt <= (endLt ?? .max) }
                .sorted { ascending ? $0.lt < $1.lt : $0.lt > $1.lt }

            let start = cursor.flatMap { Int($0.dropFirst("c".count)) } ?? 0
            let wire = Array(matching.dropFirst(start).prefix(limit))
            let more = start + limit < matching.count
            return TonJettonPage(
                actions: wire.filter { !unreadable.contains($0.actionId) },
                nextCursor: more ? "c\(start + limit)" : nil
            )
        }
    }

    private func scanner(_ indexer: Indexer) -> TonJettonScanner {
        TonJettonScanner { ascending, startLt, endLt, limit, cursor in
            indexer.fetch(ascending: ascending, startLt: startLt, endLt: endLt, limit: limit, cursor: cursor)
        }
    }

    @Test func anAccountWithoutJettonsStartsFromAnEmptyWatermark() async throws {
        let step = try await scanner(Indexer([])).step(backfill: nil, forward: nil)
        #expect(step.actions.isEmpty)
        #expect(step.backfill == nil)
        #expect(step.forward == TonJettonScanner.Forward(scan: nil, watermark: 0))
    }

    @Test func theBackfillReadsEveryActionOnceAndHandsOverToTheForwardWatermark() async throws {
        let all = (1 ... 120).map { action($0 * 1_000_000) }
        let step = try await scanner(Indexer(all)).step(backfill: nil, forward: nil)

        #expect(Set(step.actions.map(\.actionId)) == Set(all.map(\.actionId)))
        #expect(step.actions.count == 120)
        #expect(step.backfill == nil)
        #expect(step.forward?.watermark == 120_000_000)
    }

    @Test func aLongBackfillResumesWhereItStoppedWithoutRereadingOrSkipping() async throws {
        let count = TonJettonScanner.pageSize * TonJettonScanner.pagesPerPass + 70
        let indexer = Indexer((1 ... count).map { action(UInt64($0) * 1_000_000) })
        var seen: [String] = []
        var backfill: TonJettonScanner.Backfill?
        var forward: TonJettonScanner.Forward?

        for _ in 0 ..< 3 {
            let step = try await scanner(indexer).step(backfill: backfill, forward: forward)
            seen += step.actions.map(\.actionId)
            backfill = step.backfill
            forward = step.forward

            // A newer action arrives while the backfill is in progress: its offsets must not shift.
            if backfill != nil {
                indexer.actions.append(action(UInt64(count + 5) * 1_000_000))
            }

            if backfill == nil {
                break
            }
        }

        #expect(backfill == nil)
        #expect(Set(seen).count == count)
        #expect(seen.count == count)
    }

    @Test func anUnreadableActionOnAFullPageDoesNotEndTheScan() async throws {
        let all = (1 ... 120).map { action($0 * 1_000_000) }
        let indexer = Indexer(all)
        indexer.unreadable = [all[100].actionId]

        let step = try await scanner(indexer).step(backfill: nil, forward: nil)
        #expect(step.actions.count == 119)
        #expect(step.backfill == nil)
        #expect(step.forward?.watermark == 120_000_000)
    }

    @Test func anUnreadableNewestActionDoesNotSkipTheBackfill() async throws {
        let all = (1 ... 120).map { action($0 * 1_000_000) }
        let indexer = Indexer(all)
        // The whole first page is unreadable, yet the provider still has more.
        indexer.unreadable = Set(all.suffix(TonJettonScanner.pageSize).map(\.actionId))

        let step = try await scanner(indexer).step(backfill: nil, forward: nil)
        #expect(step.backfill == nil)
        #expect(step.forward?.watermark == 70_000_000)
        #expect(step.actions.count == 70)
    }

    @Test func aProbeThatFindsNothingReadableYetResumesWhereItStopped() async throws {
        let pass = TonJettonScanner.pageSize * TonJettonScanner.pagesPerPass
        let all = (1 ... pass + 30).map { action(UInt64($0) * 1_000_000) }
        let indexer = Indexer(all)
        // The newest ten pages are unreadable; the readable ones start on page 11.
        indexer.unreadable = Set(all.suffix(pass).map(\.actionId))

        let first = try await scanner(indexer).step(backfill: nil, forward: nil)
        #expect(first.actions.isEmpty)
        #expect(first.forward == nil)
        let resumed = try #require(first.backfill)
        #expect(resumed.endLt == nil)
        #expect(resumed.cursor != nil)

        let second = try await scanner(indexer).step(backfill: resumed, forward: nil)
        #expect(second.actions.count == 30)
        #expect(second.backfill == nil)
        #expect(second.forward?.watermark == 30_000_000)
    }

    @Test func theBackfillBoundIsTheNewestTraceEndNotTheActionEnd() async throws {
        // `lt` is the trace end lt, so the cap includes an action whose own end precedes its trace's.
        let early = action(5_000_000)
        let step = try await scanner(Indexer([early])).step(backfill: nil, forward: nil)
        #expect(step.actions == [early])
        #expect(step.forward?.watermark == 5_000_000)
    }

    @Test func anActionVisibleOnlyAfterTheScanFinishedIsFoundInsideTheOverlap() async throws {
        let indexer = Indexer((1 ... 10).map { action(UInt64($0) * 1_000_000_000) })
        let first = try await scanner(indexer).step(backfill: nil, forward: nil)
        let watermark = try #require(first.forward?.watermark)

        // Indexed late, with a logical time before the watermark but within the overlap.
        let late = action(watermark - 10_000_000)
        indexer.actions.append(late)

        let next = try await scanner(indexer).step(backfill: nil, forward: first.forward)
        #expect(next.actions.map(\.actionId).contains(late.actionId))
        #expect(next.forward?.watermark == watermark)
    }

    @Test func theForwardPassAddsNewActionsAndMovesTheWatermark() async throws {
        let indexer = Indexer([action(5_000_000_000)])
        let first = try await scanner(indexer).step(backfill: nil, forward: nil)
        indexer.actions.append(action(6_000_000_000))

        let next = try await scanner(indexer).step(backfill: nil, forward: first.forward)
        #expect(next.forward?.watermark == 6_000_000_000)
        #expect(next.forward?.scan == nil)
    }
}
