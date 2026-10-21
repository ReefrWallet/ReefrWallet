//
//  HardwareKeyPromptCenter.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 21.10.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation
import Observation

// MARK: - HardwareKeyPrompt

/// What the user must do on a hardware key for the running operation to continue.
struct HardwareKeyPrompt: Equatable, Identifiable {
    enum Kind {
        /// The key is waiting for the user to confirm on it.
        case confirm
        /// The key isn't connected.
        case connect
    }

    /// The key store's name.
    let keyName: String
    let kind: Kind

    /// Stable across kinds so a presented sheet updates in place.
    var id: String {
        keyName
    }

    /// Text shown to the user.
    var message: String {
        switch kind {
        case .confirm:
            "Continue on \(keyName)"
        case .connect:
            "Connect \(keyName) to continue"
        }
    }

    /// SF Symbol shown above ``message``.
    var systemImage: String {
        switch kind {
        case .confirm:
            "hand.tap"
        case .connect:
            "cable.connector"
        }
    }
}

// MARK: - HardwareKeyPromptCenter

/// UI state for ``HardwareKeyPrompt``s raised by ``HardwareService``.
///
/// Views opt in with `.hardwareKeyPromptHost()`; only the most recently
/// appeared host presents, so the prompt stacks on top of whatever sheet
/// started the operation instead of replacing it.
@MainActor @Observable
final class HardwareKeyPromptCenter {
    /// Whether the user cancelled the current connect prompt.
    private(set) var isCancelled = false
    /// The prompt to present, if any.
    private(set) var prompt: HardwareKeyPrompt?

    /// Registered hosts in appearance order.
    private var hostIds: [UUID] = []
    /// Key store names by device ID.
    private var keyNames: [String: String] = [:]
    /// Number of open ``HardwareService`` sessions.
    private var sessionCount = 0

    nonisolated init() {}

    /// The host that presents ``prompt``.
    var topHostId: UUID? {
        hostIds.last
    }

    /// Registers a host when it appears.
    func addHost(_ id: UUID) {
        hostIds.append(id)
    }

    /// Opens a session; the outermost one resets ``isCancelled``.
    func beginSession() {
        if sessionCount == 0 {
            isCancelled = false
        }

        sessionCount += 1
    }

    /// Cancels waiting for the key to be connected and hides the prompt.
    func cancel() {
        isCancelled = true
        prompt = nil
    }

    /// Hides the prompt.
    func dismiss() {
        prompt = nil
    }

    /// Closes a session; closing the outermost one hides the prompt.
    func endSession() {
        sessionCount = max(sessionCount - 1, 0)

        if sessionCount == 0 {
            prompt = nil
        }
    }

    /// Remembers `keyName` for confirm prompts from `deviceId`.
    func register(keyName: String, deviceId: String) {
        keyNames[deviceId] = keyName
    }

    /// Unregisters a host when it disappears.
    func removeHost(_ id: UUID) {
        hostIds.removeAll { $0 == id }
    }

    /// Shows "Continue on" for `deviceId`, named by its key store, or by
    /// `fallbackName` if it wasn't registered.
    func showConfirm(deviceId: String, fallbackName: String) {
        prompt = HardwareKeyPrompt(keyName: keyNames[deviceId] ?? fallbackName, kind: .confirm)
    }

    /// Shows "Connect" for `keyName`.
    func showConnect(keyName: String) {
        isCancelled = false
        prompt = HardwareKeyPrompt(keyName: keyName, kind: .connect)
    }
}
