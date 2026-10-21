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
    /// Whether `currentRequest` was approved and is still being handled.
    private(set) var isProcessing = false
    private var pendingRequestId: UUID?
    private var pendingResult: ((DappApprovalResult) -> Void)?
    private var processingRequestId: UUID?

    func didFinishRequest(_ requestId: UUID) async {
        guard isProcessing, processingRequestId == requestId else {
            return
        }

        currentRequest = nil
        isProcessing = false
        processingRequestId = nil
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
        isProcessing = false
        pendingRequestId = DappRequestScope.id
        processingRequestId = nil
        return await withCheckedContinuation { continuation in
            pendingResult = { result in
                continuation.resume(returning: result)
            }
        }
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
