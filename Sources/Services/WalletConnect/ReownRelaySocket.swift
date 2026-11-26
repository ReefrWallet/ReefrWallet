//
//  ReownRelaySocket.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 23.11.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation

#if canImport(WalletConnectSign)

#if os(macOS)
import AppKit
#endif
import WalletConnectRelay

struct ReownRelaySocketFactory: WebSocketFactory {
    func create(with url: URL) -> WebSocketConnecting {
        ReownRelaySocket(url: url)
    }
}

/// Reown's relay transport over `URLSessionWebSocketTask`. Callbacks from replaced tasks are
/// ignored, and pings catch connections that died silently (sleep, network change) so Reown
/// sees the drop and reconnects.
private final class ReownRelaySocket: NSObject, WebSocketConnecting, URLSessionWebSocketDelegate,
    @unchecked Sendable {
    private static let pingInterval: TimeInterval = 20
    private static let pongTimeout: TimeInterval = 10

    var onConnect: (() -> Void)?
    var onDisconnect: ((Error?) -> Void)?
    var onText: ((String) -> Void)?
    var request: URLRequest

    private var connected = false
    private let lock = NSLock()
    private var pendingPing = 0
    private var pingCount = 0
    private var pingTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "xyz.reefr.wallet.walletconnect.socket")
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var wakeObserver: NSObjectProtocol?

    var isConnected: Bool {
        lock.withLock { connected }
    }

    init(url: URL) {
        request = URLRequest(url: url)
        super.init()

        // The session retains its delegate; Reown keeps one socket for the app's lifetime.
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

#if os(macOS)
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            Logger.verbose("WC socket: system woke, checking connection")
            self?.pingCurrentTask()
        }
#endif
    }

    func connect() {
        guard let task = session?.webSocketTask(with: request) else {
            return
        }

        let previous = lock.withLock {
            let previous = self.task
            self.task = task
            connected = false
            stopPinging()
            return previous
        }

        Logger.verbose("WC socket connecting\(previous == nil ? "" : ", replacing the previous connection")")
        previous?.cancel(with: .goingAway, reason: nil)
        task.resume()
        receive(from: task)
    }

    func disconnect() {
        let task = lock.withLock {
            let task = self.task
            self.task = nil
            connected = false
            stopPinging()
            return task
        }

        guard let task else {
            return
        }

        Logger.verbose("WC socket disconnecting")
        task.cancel(with: .normalClosure, reason: nil)
        onDisconnect?(nil)
    }

    func write(string: String, completion: (() -> Void)?) {
        guard let task = lock.withLock({ self.task }) else {
            Logger.verbose("WC socket send skipped: not connected")
            completion?()
            return
        }

        task.send(.string(string)) { error in
            if let error {
                Logger.verbose("WC socket send failed: \(error.localizedDescription)")
            }

            completion?()
        }
    }

    // MARK: URLSessionWebSocketDelegate

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        let isCurrent = lock.withLock {
            guard self.task === webSocketTask else {
                return false
            }

            connected = true
            startPinging(webSocketTask)
            return true
        }

        guard isCurrent else {
            return
        }

        Logger.verbose("WC socket connected")
        onConnect?()
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        close(webSocketTask, error: nil, reason: "closed by relay, code \(closeCode.rawValue)")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let task = task as? URLSessionWebSocketTask else {
            return
        }

        close(task, error: error, reason: "task completed")
    }

    // MARK: Private

    /// Reports the drop once, and only for the current task.
    private func close(_ task: URLSessionWebSocketTask, error: Error?, reason: String) {
        let isCurrent = lock.withLock {
            guard self.task === task else {
                return false
            }

            self.task = nil
            connected = false
            stopPinging()
            return true
        }

        guard isCurrent else {
            return
        }

        Logger.verbose("WC socket dropped: \(reason)\(error.map { ", \($0.localizedDescription)" } ?? "")")
        task.cancel()
        onDisconnect?(error)
    }

    private func ping(_ task: URLSessionWebSocketTask) {
        let id: Int? = lock.withLock {
            guard self.task === task, connected else {
                return nil
            }

            pingCount += 1
            pendingPing = pingCount
            return pingCount
        }

        guard let id else {
            return
        }

        task.sendPing { [weak self] error in
            guard let self else {
                return
            }

            if let error {
                close(task, error: error, reason: "ping failed")
                return
            }

            lock.withLock {
                if self.pendingPing == id {
                    self.pendingPing = 0
                }
            }
        }

        queue.asyncAfter(deadline: .now() + Self.pongTimeout) { [weak self] in
            guard let self, lock.withLock({ self.task === task && self.pendingPing == id }) else {
                return
            }

            close(task, error: URLError(.timedOut), reason: "no pong in \(Int(Self.pongTimeout)) s")
        }
    }

    private func pingCurrentTask() {
        guard let task = lock.withLock({ self.task }) else {
            return
        }

        ping(task)
    }

    private func receive(from task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else {
                return
            }

            switch result {
            case let .success(message):
                if case let .string(text) = message, lock.withLock({ self.task === task }) {
                    onText?(text)
                }

                receive(from: task)
            case let .failure(error):
                close(task, error: error, reason: "receive failed")
            }
        }
    }

    /// Call with `lock` held.
    private func startPinging(_ task: URLSessionWebSocketTask) {
        stopPinging()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.pingInterval, repeating: Self.pingInterval)
        timer.setEventHandler { [weak self, weak task] in
            guard let self, let task else {
                return
            }

            ping(task)
        }

        timer.resume()
        pingTimer = timer
    }

    /// Call with `lock` held.
    private func stopPinging() {
        pingTimer?.cancel()
        pingTimer = nil
        pendingPing = 0
    }
}

#endif
