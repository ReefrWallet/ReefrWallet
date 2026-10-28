//
//  DappApprover.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 25.09.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI

/// The `@MainActor`/`@Observable` UI-facing implementation of
/// ``DappApproving`` — presents `currentRequest` via
/// ``DappRequestSheet`` and resolves the pending decision back to
/// whichever ``DappProvider`` is waiting on it.
@MainActor
@Observable
final class DappApprover: DappApproving {
    private(set) var currentRequest: DappApprovalRequest?
    /// The last approved request's failure, shown as an alert until dismissed.
    var failureMessage: String?
    /// Whether the approved `currentRequest` finished and "Complete" is showing.
    private(set) var isCompleted = false
    /// Whether `currentRequest` was approved and is still being handled.
    private(set) var isProcessing = false
    private var chosenAccounts: [DappNamespace: Account] = [:]
    private var pendingRequestId: UUID?
    private var pendingResult: ((DappApprovalResult) -> Void)?
    private var processingRequestId: UUID?

    private static let completionDelay = Duration.seconds(1)

    /// The popup to show over the approved request's sheet.
    var progressPrompt: HostedPrompt? {
        if isCompleted {
            .complete("Complete")
        } else if isProcessing {
            .progress("Signing")
        } else {
            nil
        }
    }

    func didFinishRequest(_ requestId: UUID, error: (any Error)?) async {
        guard isProcessing, processingRequestId == requestId else {
            return
        }

        if let error {
            printError("Approved dapp request failed: \(error)")
            failureMessage = failureMessage ?? error.localizedDescription
            finishProcessing()
            return
        }

        // Show "Complete" without holding up the dapp's response.
        isCompleted = true
        Task {
            try? await Task.sleep(for: Self.completionDelay)
            guard isCompleted, processingRequestId == requestId else {
                return
            }

            finishProcessing()
        }
    }

    func reportFailure(_ message: String) async {
        failureMessage = message
    }

    func approve(_ request: DappApprovalRequest) async -> DappApprovalResult {
        // A still-pending prompt would lose its continuation here. The
        // session's serial approval queue shouldn't let that happen; reject it
        // rather than leak if it ever does.
        rejectPending()

        currentRequest = request
        isCompleted = false
        isProcessing = false
        pendingRequestId = DappRequestScope.id
        processingRequestId = nil
        return await withCheckedContinuation { continuation in
            pendingResult = { result in
                continuation.resume(returning: result)
            }
        }
    }

    /// Asks which account to connect with on each chain; `nil` if the user rejects.
    func chooseAccounts(origin: String, selections: [DappAccountSelection]) async -> [DappNamespace: Account]? {
        chosenAccounts = [:]
        let result = await approve(.chooseAccounts(origin: origin, selections: selections))
        defer { chosenAccounts = [:] }

        guard case .approved = result else {
            return nil
        }

        return chosenAccounts
    }

    /// The sheet's Approve: records the accounts, then resolves the prompt.
    func resolveAccountChoices(_ accounts: [DappNamespace: Account]) {
        chosenAccounts = accounts
        resolve(.approved)
    }

    /// Rejects whatever prompt is still open, if any — the browser window
    /// going away while one is up.
    ///
    /// Every path that takes the prompt off screen must come through here or
    /// ``resolve(_:)``: the waiting provider is suspended on a continuation
    /// that only these resume, and it holds ``DappSession``'s exclusive
    /// approval slot until it does, so an unresolved prompt both leaks the
    /// continuation and deadlocks every later approval in that session.
    func rejectPending() {
        guard pendingResult != nil else {
            return
        }

        resolve(.rejected)
    }

    private func finishProcessing() {
        currentRequest = nil
        isCompleted = false
        isProcessing = false
        processingRequestId = nil
    }

    /// Resolves the currently presented request with the user's decision.
    /// A no-op when nothing is pending.
    ///
    /// With `keepsPresented`, an approved request stays presented until it
    /// finishes, so hardware key prompts can present on top of its sheet.
    func resolve(_ result: DappApprovalResult, keepsPresented: Bool = false) {
        if case .rejected = result {
            currentRequest = nil
        } else if keepsPresented, let pendingRequestId {
            isProcessing = true
            processingRequestId = pendingRequestId
        } else {
            currentRequest = nil
        }

        pendingResult?(result)
        pendingRequestId = nil
        pendingResult = nil
    }
}
