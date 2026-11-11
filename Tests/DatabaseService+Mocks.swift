import Foundation
import SwiftData
@testable import ReefrWallet
import WalletKit

extension DatabaseService {
    func keyStoreCount() throws -> Int {
        try modelContext.fetchCount(FetchDescriptor<KeyStoreModel>())
    }

    /// Creates a local test keystore from a known mnemonic so every generated
    /// account can also sign transactions on the local node.
    func makeMockKeyStore(
        mnemonic: Mnemonic,
        name: String = "Test Key Store"
    ) throws -> KeyStore {
        let id = try insertKeyStore(KeyStore(
            deviceId: nil,
            kind: .local,
            name: name,
            mnemonicWordlist: mnemonic.wordlist,
            sealedEntropy: mnemonic.entropy,
            transport: nil,
            vendor: nil
        ))

        return KeyStore(
            deviceId: nil,
            id: id,
            kind: .local,
            name: name,
            mnemonicWordlist: mnemonic.wordlist,
            sealedEntropy: mnemonic.entropy,
            transport: nil,
            vendor: nil
        )
    }

    func makeMockEthereumAccounts(
        keyStore: KeyStore,
        chainId: UInt64,
        rpcURLOverride: URL,
        count: Int = 2
    ) throws -> [ReefrWallet.Account] {
        try makeMockAccounts(
            blockchain: .evm(.custom(chainId)),
            curve: .secp256k1,
            keyStore: keyStore,
            rpcURLOverride: rpcURLOverride,
            count: count,
            path: { "m/44'/60'/0'/0/\($0)" }
        )
    }

    func makeMockSuiAccounts(
        keyStore: KeyStore,
        rpcURLOverride: URL,
        count: Int = 2
    ) throws -> [ReefrWallet.Account] {
        try makeMockAccounts(
            blockchain: .sui(.testnet),
            curve: .ed25519,
            keyStore: keyStore,
            rpcURLOverride: rpcURLOverride,
            count: count,
            path: { "m/44'/784'/0'/0'/\($0)'" }
        )
    }
}

private extension DatabaseService {
    func makeMockAccounts(
        blockchain: Blockchain,
        curve: Curve,
        keyStore: KeyStore,
        rpcURLOverride: URL,
        count: Int,
        path: (Int) -> String
    ) throws -> [ReefrWallet.Account] {
        guard count > 0, let keyStoreId = keyStore.id else {
            throw ReefrError.invalidData
        }

        let seed = try Seed(rawBytes: keyStore.plainSeed())

        return try (0 ..< count).map { index in
            let derivationPath = try DerivationPath(string: path(index))
            let privateKey = try seed.masterKey(curve: curve).derive(derivationPath).privateKey()

            let address = try makeMockAddress(
                blockchain: blockchain,
                curve: curve,
                privateKey: privateKey,
                path: derivationPath
            )

            var account = Account(
                address: address,
                blockchain: blockchain,
                derivationPath: derivationPath,
                keyStoreId: keyStoreId,
                name: "\(blockchain.displayName) #\(index + 1)",
                rpcURLOverride: rpcURLOverride,
                signatureScheme: curve
            )

            account.id = try insertAccount(account, keyStore: keyStore)
            return account
        }
    }

    func makeMockAddress(
        blockchain: Blockchain,
        curve: Curve,
        privateKey: PrivateKey,
        path: DerivationPath
    ) throws -> String {
        switch blockchain {
        case .aptos:
            return try AptosAddress(publicKey: privateKey.publicKey, curve: curve).string
        case .evm:
            return try EthereumPKeySigner(privateKey: privateKey, derivationPath: path).address().checksummed
        case .sui:
            return try SuiAddress(publicKey: privateKey.publicKey, curve: curve).string
        default:
            throw ReefrError.notImplemented
        }
    }
}
