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
        /// The key is connected and busy, e.g. exporting public keys.
        case wait
    }

    /// The device vendor's name, e.g. "Trezor".
    let vendorName: String
    let kind: Kind

    /// Stable across kinds so a presented sheet updates in place.
    var id: String {
        vendorName
    }

    /// Text shown to the user.
    var message: String {
        switch kind {
        case .confirm:
            String(localized: .hardwareKeyPromptConfirmOnDevice(vendorName))
        case .connect:
            String(localized: .hardwareKeyPromptConnectDevice(vendorName))
        case .wait:
            String(localized: .hardwareKeyPromptReadingDevice(vendorName))
        }
    }

    /// SF Symbol shown above ``message``.
    var systemImage: String {
        switch kind {
        case .confirm:
            "hand.tap"
        case .connect:
            "cable.connector"
        case .wait:
            "progress.indicator"
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
    /// Number of open ``HardwareService`` sessions.
    private var sessionCount = 0
    /// Number of open sessions that show ``HardwareKeyPrompt/Kind/wait`` once connected.
    private var waitSessionCount = 0

    nonisolated init() {}

    /// The host that presents ``prompt``.
    var topHostId: UUID? {
        hostIds.last
    }

    /// Registers a host when it appears.
    func addHost(_ id: UUID) {
        hostIds.append(id)
        Logger.verbose("HUD addHost \(id.short), hosts: \(hostDescription)")
    }

    /// Opens a session; the outermost one resets ``isCancelled``.
    func beginSession(showsWait: Bool) {
        if sessionCount == 0 {
            isCancelled = false
        }

        sessionCount += 1

        if showsWait {
            waitSessionCount += 1
        }

        Logger.verbose("HUD beginSession showsWait: \(showsWait), sessions: \(sessionCount)")
    }

    /// Cancels waiting for the key to be connected and hides the prompt.
    func cancel() {
        Logger.verbose("HUD cancel")
        isCancelled = true
        prompt = nil
    }

    /// Shows "please wait" for `vendorName` if an open session asked for it.
    func didConnect(vendorName: String) {
        Logger.verbose("HUD didConnect, waitSessions: \(waitSessionCount)")

        if waitSessionCount > 0 {
            prompt = HardwareKeyPrompt(vendorName: vendorName, kind: .wait)
        }
    }

    /// Hides the prompt.
    func dismiss() {
        Logger.verbose("HUD dismiss, prompt: \(String(describing: prompt?.kind))")
        prompt = nil
    }

    /// Closes a session; closing the outermost one hides the prompt.
    func endSession(showsWait: Bool) {
        sessionCount = max(sessionCount - 1, 0)

        if showsWait {
            waitSessionCount = max(waitSessionCount - 1, 0)
        }

        Logger.verbose("HUD endSession showsWait: \(showsWait), sessions: \(sessionCount)")

        if sessionCount == 0 {
            prompt = nil
        }
    }

    /// Unregisters a host when it disappears.
    func removeHost(_ id: UUID) {
        hostIds.removeAll { $0 == id }
        Logger.verbose("HUD removeHost \(id.short), hosts: \(hostDescription)")
    }

    /// Shows "Continue on" for the device's vendor, e.g. "Trezor".
    func showConfirm(vendorName: String) {
        Logger.verbose("HUD showConfirm, hosts: \(hostDescription)")
        prompt = HardwareKeyPrompt(vendorName: vendorName, kind: .confirm)
    }

    /// Shows "Connect" for `vendorName`.
    func showConnect(vendorName: String) {
        Logger.verbose("HUD showConnect, hosts: \(hostDescription)")
        isCancelled = false
        prompt = HardwareKeyPrompt(vendorName: vendorName, kind: .connect)
    }

    /// Registered host ids, top last, for logging.
    var hostDescription: String {
        hostIds.map(\.short).joined(separator: ", ")
    }
}

extension UUID {
    /// First 4 characters, for logging.
    var short: String {
        String(uuidString.prefix(4))
    }
}
