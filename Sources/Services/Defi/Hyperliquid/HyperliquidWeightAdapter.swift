//
//  HyperliquidWeightAdapter.swift
//  Reefr Wallet
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Alamofire
import Foundation
import Synchronization

/// Paces `/info` dispatches by documented REST weight with a token bucket.
/// Runs after WalletKit's gate on every attempt, so retries are charged and a
/// backlog released after backoff is still paced. See ADR-074.
final class HyperliquidWeightAdapter: RequestAdapter, EventMonitor, Sendable {
    struct Bucket: Sendable {
        /// Half the 1,200/min IP limit, leaving room for the in-app browser.
        static let standard = Bucket(capacity: 100, refillPerSecond: 10)

        /// The most weight dispatched at once from a full bucket.
        let capacity: Double
        let refillPerSecond: Double
    }

    private struct State {
        /// Ids cancelled before their adapt registered, so it fails at once.
        var cancelled: Set<UUID> = []
        var timer: Task<Void, Never>?
        var tokens: Double
        var updatedAt: ContinuousClock.Instant
        var waiters: [Waiter] = []
    }

    private struct Waiter {
        let completion: @Sendable (Result<URLRequest, any Error>) -> Void
        let id: UUID
        let request: URLRequest
        let weight: Double
    }

    let bucket: Bucket
    let queue = DispatchQueue(label: "xyz.reefr.wallet.hyperliquid-weights")

    private let clock = ContinuousClock()
    private let state: Mutex<State>

    init(bucket: Bucket = .standard) {
        self.bucket = bucket
        state = Mutex(State(tokens: bucket.capacity, updatedAt: ContinuousClock().now))
    }

    /// Requests waiting for weight.
    var waitingCount: Int {
        state.withLock { $0.waiters.count }
    }

    // MARK: - RequestAdapter

    func adapt(
        _ urlRequest: URLRequest,
        for session: Session,
        completion: @escaping @Sendable (Result<URLRequest, any Error>) -> Void
    ) {
        // Without a request id a waiter couldn't be cancelled; never waits.
        completion(.success(urlRequest))
    }

    func adapt(
        _ urlRequest: URLRequest,
        using state: RequestAdapterState,
        completion: @escaping @Sendable (Result<URLRequest, any Error>) -> Void
    ) {
        let weight = min(Double(Self.weight(of: urlRequest)), bucket.capacity)
        let waiter = Waiter(completion: completion, id: state.requestID, request: urlRequest, weight: weight)

        let isCancelled = self.state.withLock { state in
            guard state.cancelled.remove(waiter.id) == nil else {
                return true
            }

            state.waiters.append(waiter)
            return false
        }

        if isCancelled {
            completion(.failure(CancellationError()))
            return
        }

        pump()
    }

    // MARK: - EventMonitor

    func requestDidCancel(_ request: Request) {
        let removed = state.withLock { state -> Waiter? in
            guard let index = state.waiters.firstIndex(where: { $0.id == request.id }) else {
                state.cancelled.insert(request.id)
                return nil
            }

            state.timer?.cancel()
            state.timer = nil
            return state.waiters.remove(at: index)
        }

        removed?.completion(.failure(CancellationError()))
        pump()
    }

    func requestDidFinish(_ request: Request) {
        state.withLock { _ = $0.cancelled.remove(request.id) }
    }

    // MARK: - Private

    static func weight(of request: URLRequest) -> Int {
        let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        return HyperliquidRequest.weight(type: body?["type"] as? String)
    }

    /// Admits waiters in order while the bucket covers them, then sleeps until the head fits.
    private func pump() {
        let now = clock.now
        let admitted = state.withLock { state -> [Waiter] in
            let elapsed = now - state.updatedAt
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            state.tokens = min(bucket.capacity, state.tokens + seconds * bucket.refillPerSecond)
            state.updatedAt = now

            var admitted: [Waiter] = []

            while let head = state.waiters.first, head.weight <= state.tokens {
                state.tokens -= head.weight
                admitted.append(state.waiters.removeFirst())
            }

            if let head = state.waiters.first, state.timer == nil {
                let delay = (head.weight - state.tokens) / bucket.refillPerSecond
                state.timer = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(delay))
                    guard !Task.isCancelled, let self else {
                        return
                    }

                    self.state.withLock { $0.timer = nil }
                    self.pump()
                }
            }

            return admitted
        }

        for waiter in admitted {
            waiter.completion(.success(waiter.request))
        }
    }
}
