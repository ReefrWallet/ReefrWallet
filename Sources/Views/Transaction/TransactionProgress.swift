//
//  TransactionProgress.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 06.11.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI

/// The stages of a send, shown in the prompt popup while a ``TransactionSheet`` is processing.
enum TransactionProgress {
    case complete
    case preparing
    case sending
    case signing

    var prompt: HostedPrompt {
        switch self {
        case .complete:
            .complete(String(localized: .commonComplete))
        case .preparing:
            .progress(String(localized: .transferPreparingTransaction))
        case .sending:
            .progress(String(localized: .transferSendingTransaction))
        case .signing:
            .progress(String(localized: .transferSigningTransaction))
        }
    }
}

extension Binding where Value == TransactionProgress? {
    /// Shows `.preparing` while `work` runs (it may move on to `.signing` and `.sending`), then
    /// `.complete` for a second. Clears the progress and rethrows if `work` fails.
    @MainActor
    func track(_ work: () async throws -> Void) async throws {
        do {
            wrappedValue = .preparing
            try await work()
            wrappedValue = .complete
            try? await Task.sleep(for: .seconds(1))
            wrappedValue = nil
        } catch {
            wrappedValue = nil
            throw error
        }
    }
}
