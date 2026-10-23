import Foundation
@testable import ReefrWallet
import WalletKit

extension KeyStore {
    /// Seed of a test key store, whose entropy is unsealed (`PassthroughKeyVault`).
    func plainSeed() throws -> Data {
        guard let sealedEntropy else {
            throw ReefrError.invalidData
        }

        return try Mnemonic.fromEntropy(sealedEntropy, wordlist: mnemonicWordlist ?? .english).toSeed().exportRaw()
    }
}
