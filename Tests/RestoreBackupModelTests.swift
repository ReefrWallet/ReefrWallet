// Unit tests for the restore flow state machine.

import Foundation
import Testing
import WalletKit
@testable import ReefrWallet

@MainActor
struct RestoreBackupModelTests {
    private static let bip39 = (Array(repeating: "abandon", count: 11) + ["about"]).joined(separator: " ")
    private static let single = [
        "duckling enlarge academic academic agency result length solution fridge kidney",
        "coal piece deal husband erode duke ajar critical decision keyboard"
    ].joined(separator: " ")
    private static let singleSecret = "bb54aac4b89dc868ba37d9cc21b2cece"
    private static let pair = [
        "shadow pistol academic always adequate wildlife fancy gross oasis cylinder "
            + "mustang wrist rescue view short owner flip making coding armed",
        "shadow pistol academic acid actress prayer class unknown daughter sweater "
            + "depict flip twice unkind craft early superior advocate guest smoking"
    ]
    private static let pairSecret = "b43ceb7e57a0ea8766221624d01b0864"

    final class Saved {
        var secrets: [RestoreBackupModel.Secret] = []
        var failuresLeft = 0
    }

    private func makeModel(_ saved: Saved) -> RestoreBackupModel {
        let model = RestoreBackupModel()
        model.save = { secret in
            if saved.failuresLeft > 0 {
                saved.failuresLeft -= 1
                throw ReefrError.invalidData
            }

            saved.secrets.append(secret)
        }

        return model
    }

    private func finish(_ model: RestoreBackupModel) async {
        while model.isRestoring {
            await Task.yield()
        }
    }

    private func enter(_ share: String, into model: RestoreBackupModel) async {
        model.field.load(phrase: share)
        await model.next()
    }

    private func hex(_ secret: RestoreBackupModel.Secret?) -> String? {
        guard case let .slip39(data) = secret else {
            return nil
        }

        return data.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: BIP-39

    @Test
    func bip39PhraseWithTheSelectedCountRestores() async {
        let saved = Saved()
        let model = makeModel(saved)

        await model.next()
        #expect(model.step == .words)
        #expect(!model.isNextEnabled)

        model.field.load(phrase: Self.bip39)
        #expect(model.isNextEnabled)
        #expect(model.nextRestores)

        await model.next()
        #expect(saved.secrets.count == 1)
    }

    @Test
    func aValid12WordPhraseWith24SelectedCannotSubmit() async {
        let model = makeModel(Saved())
        model.wordCount = 24
        await model.next()

        model.field.load(phrase: Self.bip39)

        #expect(!model.isNextEnabled)
    }

    @Test
    func aFullPhraseWithABadChecksumShowsTheChecksumError() async {
        let model = makeModel(Saved())
        await model.next()

        model.field.load(phrase: Array(repeating: "abandon", count: 12).joined(separator: " "))

        #expect(model.hasChecksumError)
        #expect(!model.isNextEnabled)
    }

    // MARK: SLIP-39

    @Test
    func singleShareWithPassphraseRestoresTheMasterSecret() async {
        let saved = Saved()
        let model = makeModel(saved)
        model.type = .slip39
        await model.next()

        await enter(Self.single, into: model)
        #expect(model.step == .shares)
        #expect(model.sharesCombine)

        await model.next()
        #expect(model.step == .passphrase)

        model.usesPassphrase = true
        model.passphrase = "TREZOR"
        await model.next()
        await finish(model)

        #expect(saved.secrets.count == 1)
        #expect(hex(saved.secrets.first) == Self.singleSecret)
    }

    @Test
    func backThenContinueNeedsNoNewShare() async {
        let model = makeModel(Saved())
        model.type = .slip39
        await model.next()
        await enter(Self.single, into: model)
        await model.next()
        #expect(model.step == .passphrase)

        #expect(model.back())
        #expect(model.step == .shares)
        #expect(model.sharesCombine)

        await model.next()
        #expect(model.step == .passphrase)
    }

    @Test
    func removingAShareAfterGoingBackClearsThePassphraseAndReopensTheSet() async throws {
        let model = makeModel(Saved())
        model.type = .slip39
        await model.next()
        await enter(Self.pair[0], into: model)
        #expect(!model.sharesCombine)
        await model.next()
        #expect(model.step == .words)
        await enter(Self.pair[1], into: model)
        #expect(model.sharesCombine)

        await model.next()
        model.usesPassphrase = true
        model.passphrase = "TREZOR"
        _ = model.back()

        model.removeShare(try #require(model.shares.shares.first))

        #expect(!model.sharesCombine)
        #expect(model.passphrase.isEmpty)
        #expect(!model.usesPassphrase)
        #expect(model.isTypeLocked)

        model.startOver()
        #expect(!model.isTypeLocked)
        #expect(model.step == .type)
    }

    @Test
    func aShareFromAnotherBackupIsRejectedAndKeepsTheText() async {
        let model = makeModel(Saved())
        model.type = .slip39
        await model.next()
        await enter(Self.pair[0], into: model)
        await model.next()

        await enter(Self.single, into: model)

        #expect(model.shareError != nil)
        #expect(model.step == .words)
        #expect(model.field.totalWordCount == 20)
    }

    @Test
    func doubleSubmitSavesOnce() async {
        let saved = Saved()
        let model = makeModel(saved)
        model.type = .slip39
        await model.next()
        await enter(Self.single, into: model)
        await model.next()
        model.usesPassphrase = true
        model.passphrase = "TREZOR"

        async let first: Void = model.next()
        async let second: Void = model.next()
        _ = await (first, second)

        #expect(saved.secrets.count == 1)
    }

    @Test
    func dismissingDuringDerivationSavesNothing() async {
        let saved = Saved()
        let model = makeModel(saved)
        model.type = .slip39
        await model.next()
        await enter(Self.single, into: model)
        await model.next()
        model.usesPassphrase = true
        model.passphrase = "TREZOR"

        let restoring = Task { await model.next() }
        await Task.yield()
        model.cancel()
        await restoring.value
        try? await Task.sleep(for: .milliseconds(300))

        #expect(saved.secrets.isEmpty)
        #expect(!model.isRestoring)
    }

    @Test
    func aFailedSaveShowsAnErrorAndRetrySucceeds() async {
        let saved = Saved()
        saved.failuresLeft = 1
        let model = makeModel(saved)
        model.type = .slip39
        await model.next()
        await enter(Self.single, into: model)
        await model.next()
        model.usesPassphrase = true
        model.passphrase = "TREZOR"

        await model.next()
        await finish(model)
        #expect(model.failure != nil)
        #expect(saved.secrets.isEmpty)
        #expect(model.step == .passphrase)

        await model.next()
        await finish(model)
        #expect(model.failure == nil)
        #expect(saved.secrets.count == 1)
    }

    @Test
    func aNonASCIIPassphraseDisablesRestore() async {
        let model = makeModel(Saved())
        model.type = .slip39
        await model.next()
        await enter(Self.single, into: model)
        await model.next()

        model.usesPassphrase = true
        model.passphrase = "pässword"

        #expect(!model.isNextEnabled)
    }

    @Test
    func bip39DoubleSubmitSavesOnce() async {
        let saved = Saved()
        let model = makeModel(saved)
        await model.next()
        model.field.load(phrase: Self.bip39)

        async let first: Void = model.next()
        async let second: Void = model.next()
        _ = await (first, second)

        #expect(saved.secrets.count == 1)
    }

    @Test
    func aCancelledAttemptDoesNotEndTheRetry() async {
        let saved = Saved()
        let model = RestoreBackupModel()
        var calls = 0
        model.save = { secret in
            calls += 1
            // Not cancellable, so the first attempt outlives its cancel.
            await Task.detached { try? await Task.sleep(for: .milliseconds(calls == 1 ? 100 : 500)) }.value
            saved.secrets.append(secret)
        }

        await model.next()
        model.field.load(phrase: Self.bip39)

        let first = Task { await model.next() }

        while calls == 0 {
            await Task.yield()
        }

        model.cancel()
        let second = Task { await model.next() }
        await Task.yield()

        try? await Task.sleep(for: .milliseconds(250))
        #expect(model.isRestoring, "The first attempt finished and must not clear the retry's state.")

        await first.value
        await second.value
        #expect(!model.isRestoring)
    }

    @Test
    func aFailedBip39SaveKeepsThePhraseForRetry() async {
        let saved = Saved()
        saved.failuresLeft = 1
        let model = makeModel(saved)
        await model.next()
        model.field.load(phrase: Self.bip39)

        await model.next()
        #expect(model.failure != nil)
        #expect(model.step == .words)
        #expect(model.field.isComplete)

        await model.next()
        #expect(model.failure == nil)
        #expect(saved.secrets.count == 1)
    }

    @Test
    func backIsIgnoredOnceSavingStartsAndTheFlowEndsOnce() async {
        let model = RestoreBackupModel()
        var saveStarted = false
        var release: CheckedContinuation<Void, Never>?
        var dismissals = 0
        model.save = { _ in
            saveStarted = true
            await withCheckedContinuation { release = $0 }
        }

        model.didSave = { dismissals += 1 }

        await model.next()
        model.field.load(phrase: Self.bip39)

        let restoring = Task { await model.next() }

        while !saveStarted || release == nil {
            await Task.yield()
        }

        #expect(model.isPersisting)
        #expect(model.back())
        #expect(model.step == .words)
        #expect(model.isRestoring)
        #expect(!model.isNextEnabled, "A retry must not start while saving.")

        release?.resume()
        await restoring.value

        #expect(dismissals == 1)
        #expect(!model.isPersisting)
    }
}
