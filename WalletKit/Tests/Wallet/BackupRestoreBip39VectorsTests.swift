// Integration test for backup/restore of Docs/Design Specification/Wallet/Wallet.swift
// and WalletBackup.swift against the official BIP39 test vectors
// (TestVectors/bip39.json, the standard Trezor python-mnemonic vectors, which
// use "TREZOR" as the passphrase when deriving each vector's seed).
// Will compile once the corresponding types are exported from Sources.

import Foundation
import Testing
@testable import WalletKit

private struct Bip39Vector: Sendable, CustomTestStringConvertible {
    let mnemonic: String
    let seedHex: String
    let xprv: String

    var testDescription: String { mnemonic }
}

private struct Bip39VectorFile: Decodable {
    let english: [[String]]
}

private func loadEnglishBip39Vectors() -> [Bip39Vector] {
    let url = Bundle.module.url(forResource: "bip39", withExtension: "json")!
    let data = try! Data(contentsOf: url)
    let file = try! JSONDecoder().decode(Bip39VectorFile.self, from: data)
    return file.english.map { row in
        Bip39Vector(mnemonic: row[1], seedHex: row[2], xprv: row[3])
    }
}

private extension String {
    /// Decodes a lowercase hex string, as used throughout the BIP39 vectors file.
    var hexDecoded: Data {
        var data = Data(capacity: count / 2)
        var index = startIndex
        while index < endIndex {
            let next = self.index(index, offsetBy: 2)
            data.append(UInt8(self[index..<next], radix: 16)!)
            index = next
        }
        return data
    }
}

private extension Data {
    var hexEncoded: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

private let vectorPassphrase = "TREZOR"

struct BackupRestoreBip39VectorsTests {
    fileprivate static let vectors = loadEnglishBip39Vectors()

    @Test(arguments: vectors)
    fileprivate func restoredMnemonicReproducesTheOfficialSeedAndMasterKey(vector: Bip39Vector) throws {
        let mnemonic = try Mnemonic.fromPhrase(vector.mnemonic)
        #expect(mnemonic.phrase == vector.mnemonic)
        #expect(mnemonic.wordlist == .english)

        let seed = mnemonic.toSeed(passphrase: vectorPassphrase)
        #expect(seed.exportRaw().hexEncoded == vector.seedHex)

        let master = try seed.masterKey(curve: .secp256k1)
        #expect(try master.serializedPrivate() == vector.xprv)
    }

    @Test(arguments: vectors)
    fileprivate func walletRestoreReproducesTheOfficialSeed(vector: Bip39Vector) throws {
        let wallet = try Wallet.restore(phrase: vector.mnemonic, passphrase: vectorPassphrase)
        #expect(wallet.mnemonic.phrase == vector.mnemonic)
        #expect(wallet.mnemonic.toSeed(passphrase: vectorPassphrase).exportRaw().hexEncoded == vector.seedHex)
    }

    @Test(arguments: vectors)
    fileprivate func exportedBackupRoundTripsBackToAnIdenticalWalletAndSeed(vector: Bip39Vector) throws {
        let original = try Wallet.restore(phrase: vector.mnemonic, passphrase: vectorPassphrase)
        let backup = original.exportBackup()
        #expect(backup.phrase == vector.mnemonic)
        #expect(backup.wordlist == .english)

        let restored = try Wallet.restore(phrase: backup.phrase, passphrase: vectorPassphrase)
        #expect(restored.mnemonic.phrase == original.mnemonic.phrase)

        let originalSeed = original.mnemonic.toSeed(passphrase: vectorPassphrase).exportRaw()
        let restoredSeed = restored.mnemonic.toSeed(passphrase: vectorPassphrase).exportRaw()
        #expect(restoredSeed == originalSeed)
        #expect(restoredSeed.hexEncoded == vector.seedHex)
    }

    @Test func restoringAKnownPhraseWithATamperedWordThrows() {
        let tampered = "zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo"
        #expect(throws: WalletKitError.self) {
            _ = try Wallet.restore(phrase: tampered)
        }
    }
}
