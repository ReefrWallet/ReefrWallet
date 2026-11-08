//
//  SuiStakingSheet+Sending.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 08.11.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI
import WalletKit

// MARK: - Preparation and sending

extension SuiStakingSheet {
    /// Builds the transaction once the inputs settle; `nil` action clears it.
    func schedulePreparation() {
        prepareTask?.cancel()
        prepared = nil
        prepareError = nil

        guard action != nil else {
            return
        }

        prepareTask = Task {
            do {
                try await Task.sleep(for: .seconds(0.5))
            } catch {
                return  // cancelled during the delay
            }

            await prepare()
        }
    }

    func prepare() async {
        guard let action else {
            return
        }

        do {
            let transaction = try await service.prepare(action, account: model.account)

            guard self.action == action else {
                return
            }

            prepared = transaction
            prepareError = nil
        } catch {
            guard !Task.isCancelled, self.action == action else {
                return
            }

            prepared = nil
            prepareError = error.localizedDescription
        }
    }

    func send(_ action: SuiStakingAction) {
        Task { @MainActor in
            do {
                try await $progress.track {
                    try await run(action)
                }

                if outcome == nil {
                    dismiss()
                }
            } catch {
                self.error = error.localizedDescription
                isErrorAlertPresented = true
            }
        }
    }

    /// Prepares again just before signing, so the epoch, gas and coins are current, then sends what was signed.
    func run(_ action: SuiStakingAction) async throws {
        let account = model.account
        let transaction = try await service.prepare(action, account: account)
        prepared = transaction

        let signature = try await service.sign(transaction, account: account)

        progress = .sending

        switch try await service.submit(transaction, signature: signature, account: account) {
        case .confirmed:
            break
        case .failed:
            outcome = .failed(digest: Base58.encode(transaction.digest))
        case .notExecuted:
            outcome = .expired(digest: Base58.encode(transaction.digest))
        case let .submitted(digest):
            outcome = .submitted(digest: digest)
        }
    }

    /// Keeps checking while the outcome is open, so the sheet follows a late confirmation.
    func followOutcome() async {
        while outcome?.isUnresolved == true, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(10))

            guard !Task.isCancelled else {
                return
            }

            await checkOutcome()
        }
    }

    func checkOutcome() async {
        guard let digest = outcome?.digest else {
            return
        }

        try? await service.checkAgain(model.account)

        switch await service.latestUpdate(for: digest) {
        case .succeeded:
            dismiss()
        case .notExecuted:
            outcome = .expired(digest: digest)
        case .failed:
            outcome = .failed(digest: digest)
        case let .unresolved(reason):
            outcome = reason == .stillValid ? .submitted(digest: digest) : .unknown(digest: digest)
        case nil:
            break
        }
    }
}
