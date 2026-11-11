//
//  RestoreBackupModel.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 11.11.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation
import Observation
import WalletKit

/// The steps of restoring a key store from a BIP-39 phrase or SLIP-39
/// shares: pick the backup type and word count, enter the words, (for
/// SLIP-39) collect shares, then give the passphrase.
@MainActor @Observable
final class RestoreBackupModel {
    enum BackupType: Equatable {
        case bip39
        case slip39

        var wordCounts: [Int] {
            switch self {
            case .bip39: [12, 15, 18, 21, 24]
            case .slip39: SeedPhraseFieldModel.supportedSlip39WordCounts
            }
        }
    }

    enum Step: Equatable {
        case passphrase
        case shares
        case type
        case words
    }

    /// What a finished restore stores.
    enum Secret {
        case bip39(Mnemonic)
        case slip39(Data)
    }

    typealias Save = (Secret) async throws -> Void

    private(set) var step = Step.type
    private(set) var shares = Slip39ShareSet()
    private(set) var field = SeedPhraseFieldModel(wordCount: 12, wordlist: .bip39(.english))
    private(set) var isPersisting = false
    private(set) var isRestoring = false
    private(set) var shareError: Slip39Error?
    private(set) var failure: Error?

    var passphrase = ""
    var usesPassphrase = false

    private var attempt = 0
    private var encryptedSecret: Slip39EncryptedSecret?
    private var restoreTask: Task<Void, Never>?

    var type = BackupType.bip39 {
        didSet { configureField() }
    }

    var wordCount = 12 {
        didSet { field.wordCount = wordCount }
    }

    /// Runs after a restore is saved, unless it was cancelled meanwhile.
    var didSave: () -> Void = {}

    /// Persists the restored secret; set by the owner of the flow.
    var save: Save = { _ in }
}

// MARK: - State

extension RestoreBackupModel {
    /// The shares combine (digest check), so the passphrase step can start.
    var sharesCombine: Bool {
        shares.isComplete && encryptedSecret != nil
    }

    /// Shown when the full phrase passes the wordlist but not the checksum.
    var hasChecksumError: Bool {
        type == .bip39 && field.isComplete && (try? Mnemonic.fromPhrase(field.phrase)) == nil
    }

    /// Type and count can't change once a share is accepted.
    var isTypeLocked: Bool { !shares.isEmpty }

    var isPassphraseValid: Bool {
        guard usesPassphrase else {
            return true
        }

        return !passphrase.isEmpty && passphrase.unicodeScalars.allSatisfy { (32 ... 126).contains($0.value) }
    }

    var isNextEnabled: Bool {
        guard !isRestoring else {
            return false
        }

        switch step {
        case .type:
            return true
        case .words:
            return field.isComplete && !hasChecksumError
        case .shares:
            return shares.isComplete ? sharesCombine : true
        case .passphrase:
            return isPassphraseValid
        }
    }

    /// Whether Next restores the key store right away.
    var nextRestores: Bool {
        (step == .words && type == .bip39) || step == .passphrase
    }
}

// MARK: - Actions

extension RestoreBackupModel {
    /// Goes back a step; `false` means the flow is at its start.
    func back() -> Bool {
        // Once persistence started the key store may already exist.
        guard !isPersisting else {
            return true
        }

        cancel()
        failure = nil

        switch step {
        case .type:
            return false
        case .words:
            step = shares.isEmpty ? .type : .shares
        case .shares:
            step = .type
        case .passphrase:
            step = .shares
        }

        return true
    }

    /// Stops a restore in progress; its result is discarded.
    func cancel() {
        attempt += 1
        restoreTask?.cancel()
        restoreTask = nil
        isPersisting = false
        isRestoring = false
    }

    func removeShare(_ share: Slip39Share) {
        shares.remove(share)
        invalidateSecret()
        shareError = nil
        updateCombine()
    }

    func startOver() {
        shares.removeAll()
        invalidateSecret()
        shareError = nil
        field.load(phrase: "")
        step = .type
    }

    /// The step's Next action. The final steps save the key store.
    func next() async {
        guard isNextEnabled else {
            return
        }

        failure = nil

        switch step {
        case .type:
            configureField()
            step = .words
        case .words:
            await finishWords()
        case .shares:
            step = sharesCombine ? .passphrase : .words
            field.load(phrase: "")
        case .passphrase:
            await restore()
        }
    }
}

// MARK: - Steps

private extension RestoreBackupModel {
    func configureField() {
        wordCount = type.wordCounts.contains(wordCount) ? wordCount : (type == .bip39 ? 12 : 20)
        field = SeedPhraseFieldModel(wordCount: wordCount, wordlist: type == .bip39 ? .bip39(.english) : .slip39)
    }

    func finishWords() async {
        switch type {
        case .bip39:
            guard let mnemonic = try? Mnemonic.fromPhrase(field.phrase) else {
                return
            }

            await run { .bip39(mnemonic) }
        case .slip39:
            addShare()
        }
    }

    func addShare() {
        do {
            let share = try Slip39.decodeShare(field.phrase)
            try shares.add(share)
            shareError = nil
            invalidateSecret()
            field.load(phrase: "")
            updateCombine()
            step = .shares
        } catch let error as Slip39Error {
            shareError = error
        } catch {
            failure = error
        }
    }

    /// Whenever the set is complete the shares are combined at once, so a
    /// digest failure shows before the passphrase step.
    func updateCombine() {
        guard shares.isComplete else {
            encryptedSecret = nil
            return
        }

        do {
            encryptedSecret = try shares.encryptedSecret()
            shareError = nil
        } catch let error as Slip39Error {
            encryptedSecret = nil
            shareError = error
        } catch {
            failure = error
        }
    }

    func invalidateSecret() {
        encryptedSecret = nil
        passphrase = ""
        usesPassphrase = false
    }

    func restore() async {
        guard let encryptedSecret else {
            return
        }

        let passphrase = usesPassphrase ? passphrase : ""
        await run { .slip39(try await encryptedSecret.decrypt(passphrase: passphrase)) }
    }

    /// Produces and saves a secret as one tracked attempt: `cancel()` stops
    /// it, and a stale attempt can't touch a newer one's state.
    func run(_ produce: @escaping () async throws -> Secret) async {
        guard restoreTask == nil else {
            return
        }

        attempt += 1
        let id = attempt
        isRestoring = true

        let task = Task { [weak self] in
            do {
                let secret = try await produce()
                try Task.checkCancellation()

                guard let self, self.attempt == id else {
                    return
                }

                self.isPersisting = true
                try await self.save(secret)

                guard self.attempt == id else {
                    return
                }

                self.end(id)
                self.didSave()
            } catch is CancellationError {
                self?.end(id)
            } catch Slip39Error.cancelled {
                self?.end(id)
            } catch {
                self?.end(id, failure: error)
            }
        }

        restoreTask = task
        await task.value
    }

    func end(_ id: Int, failure: Error? = nil) {
        guard id == attempt else {
            return
        }

        isPersisting = false
        isRestoring = false
        restoreTask = nil
        self.failure = failure
    }
}
