// Weight pacing of real HTTP attempts through the production provider
// configuration: WalletKit's gate and retrier, then the weight bucket (ADR-074).

import Alamofire
import Foundation
import Moya
import Testing
@testable import ReefrWallet

@Suite(.serialized, .timeLimit(.minutes(1)))
struct HyperliquidWeightAdapterTests {
    /// Two 20-weight requests at once, then one per half second.
    private static let bucket = HyperliquidWeightAdapter.Bucket(capacity: 40, refillPerSecond: 40)

    private func provider(statuses: [Int] = []) -> MoyaProvider<HyperliquidTarget> {
        LiveHyperliquidInfoClient.makeProvider(
            network: .testnet,
            configuration: HyperliquidStubURLProtocol.configuration(statuses: statuses),
            bucket: Self.bucket
        )
    }

    private func send(_ provider: MoyaProvider<HyperliquidTarget>, count: Int) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0 ..< count {
                group.addTask {
                    let request = HyperliquidRequest.userAbstraction(user: "0x\(index)")
                    _ = try await provider.requestData(HyperliquidTarget(network: .testnet, request: request))
                }
            }

            try await group.waitForAll()
        }
    }

    /// No window of dispatches exceeds `capacity + refill × length`, allowing 100 ms of timer slop.
    private func expectWithinBucket(_ attempts: [HyperliquidStubURLProtocol.Attempt]) {
        let sorted = attempts.sorted { $0.time < $1.time }

        for start in sorted.indices {
            var weight = 0.0

            for end in sorted.indices where end >= start {
                weight += Double(HyperliquidRequest.weight(type: sorted[end].type))
                let length = sorted[end].time - sorted[start].time
                let seconds = Double(length.components.seconds) + Double(length.components.attoseconds) / 1e18
                let allowed = Self.bucket.capacity + Self.bucket.refillPerSecond * (seconds + 0.1)

                #expect(weight <= allowed, "\(weight) weight within \(seconds) s")
            }
        }
    }

    @Test func aBurstIsCappedByCapacityAndThenPaced() async throws {
        let started = ContinuousClock.now
        try await send(provider(), count: 6)

        let attempts = HyperliquidStubURLProtocol.recorded
        #expect(attempts.count == 6)
        #expect(attempts.filter { $0.time - started < .milliseconds(250) }.count <= 2)
        expectWithinBucket(attempts)
    }

    @Test func retriesAreChargedAndABacklogAfterBackoffStaysPaced() async throws {
        try await send(provider(statuses: [429]), count: 5)

        let attempts = HyperliquidStubURLProtocol.recorded
        // Five requests plus the retried one.
        #expect(attempts.count == 6)
        expectWithinBucket(attempts)
    }

    @Test func a503ReachesTheRetrier() async throws {
        try await send(provider(statuses: [503]), count: 1)
        #expect(HyperliquidStubURLProtocol.recorded.count == 2)
    }

    @Test func cancellingAWaiterSpendsNothingAndFreesTheQueue() async throws {
        // 20 weight refills in 2 s.
        let adapter = HyperliquidWeightAdapter(bucket: .init(capacity: 20, refillPerSecond: 10))
        let session = Session(
            configuration: HyperliquidStubURLProtocol.configuration(),
            interceptor: Interceptor(adapters: [adapter], retriers: []),
            eventMonitors: [adapter]
        )

        let provider = MoyaProvider<HyperliquidTarget>(session: session)
        let target = HyperliquidTarget(network: .testnet, request: .perpDexs)

        let started = ContinuousClock.now
        _ = try await provider.requestData(target) // empties the bucket

        let cancelled = _Concurrency.Task { try await provider.requestData(target) }
        try await _Concurrency.Task.sleep(for: .milliseconds(200))
        #expect(adapter.waitingCount == 1)
        cancelled.cancel()

        await #expect(throws: (any Error).self) {
            try await cancelled.value
        }

        try await _Concurrency.Task.sleep(for: .milliseconds(100))
        #expect(adapter.waitingCount == 0)

        _ = try await provider.requestData(target)
        let elapsed = ContinuousClock.now - started

        // The live request gets the refill the cancelled one would have taken: ~2 s, not ~4 s.
        #expect(elapsed < .milliseconds(3_000))
        #expect(HyperliquidStubURLProtocol.recorded.count == 2)
    }

    @Test func cancellingBeforeTheWaiterRegistersSpendsNothing() async throws {
        let adapter = HyperliquidWeightAdapter(bucket: .init(capacity: 20, refillPerSecond: 1))
        let session = Session(
            configuration: HyperliquidStubURLProtocol.configuration(),
            interceptor: Interceptor(adapters: [adapter], retriers: []),
            eventMonitors: [adapter]
        )

        let target = HyperliquidTarget(network: .testnet, request: .perpDexs)
        let request = session.request(target.baseURL.appending(path: target.path), method: .post)
        request.cancel()

        try await _Concurrency.Task.sleep(for: .milliseconds(200))
        #expect(adapter.waitingCount == 0)

        // The full bucket still admits a 20-weight request at once.
        let started = ContinuousClock.now
        _ = try await MoyaProvider<HyperliquidTarget>(session: session).requestData(target)
        #expect(ContinuousClock.now - started < .milliseconds(500))
        #expect(HyperliquidStubURLProtocol.recorded.count == 1)
    }
}
