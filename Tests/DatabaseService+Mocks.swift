import Foundation
@testable import ReefrWallet
import WalletKitTesting

extension DatabaseService {
    /// Creates a local test keystore from a known mnemonic so every generated
    /// account can also sign transactions on the local node.
    func makeMockKeyStore(
        mnemonic: Mnemonic,
        name: String = "Test Key Store"
    ) throws -> KeyStore {
        let rawKey = mnemonic.toSeed().exportRaw()

        let id = try insertKeyStore(KeyStore(
            deviceId: nil,
            kind: .local,
            name: name,
            rawKey: rawKey,
            transport: nil,
            vendor: nil
        ))

        return KeyStore(
            deviceId: nil,
            id: id,
            kind: .local,
            name: name,
            rawKey: rawKey,
            transport: nil,
            vendor: nil
        )
    }

    func makeMockEthereumAccounts(
        keyStore: KeyStore,
        chainID: UInt64,
        rpcURLOverride: URL,
        count: Int = 2
    ) throws -> [Account] {
        try makeMockAccounts(
            blockchain: .evm(.custom(chainID)),
            curve: .secp256k1,
            keyStore: keyStore,
            rpcURLOverride: rpcURLOverride,
            count: count
        )
    }

    func makeMockSuiAccounts(
        keyStore: KeyStore,
        rpcURLOverride: URL,
        count: Int = 2
    ) throws -> [Account] {
        try makeMockAccounts(
            blockchain: .sui(.testnet),
            curve: .ed25519,
            keyStore: keyStore,
            rpcURLOverride: rpcURLOverride,
            count: count
        )
    }
}

private extension DatabaseService {
    func makeMockAccounts(
        blockchain: WKBlockchain,
        curve: Curve,
        keyStore: KeyStore,
        rpcURLOverride: URL,
        count: Int
    ) throws -> [Account] {
        guard count > 0, let keyStoreID = keyStore.id, let rawKey = keyStore.rawKey else {
            throw Error.invalidData
        }

        let seed = try Seed(rawBytes: rawKey)

        return try (0 ..< count).map { index in
            let accountIndex = UInt64(index)
            let derivationPath = try DerivationPath(blockchain, accountIndex: accountIndex, curve: curve)
            let privateKey = try seed.masterKey(curve: curve).derive(derivationPath).privateKey()

            let address = try makeMockAddress(
                blockchain: blockchain,
                curve: curve,
                privateKey: privateKey,
                path: derivationPath
            )

            var account = Account(
                accountIndex: accountIndex,
                address: address,
                blockchain: blockchain,
                derivationPath: derivationPath.string,
                keyStoreId: keyStoreID,
                name: "\(blockchain.displayName) #\(index + 1)",
                rpcURLOverride: rpcURLOverride,
                signatureScheme: curve
            )

            account.id = try insertAccount(account, keyStore: keyStore)
            return account
        }
    }

    func makeMockAddress(
        blockchain: WKBlockchain,
        curve: Curve,
        privateKey: PrivateKey,
        path: DerivationPath
    ) throws -> String {
        switch blockchain {
        case .evm:
            return try EthereumPKeySigner(privateKey: privateKey, derivationPath: path).address().checksummed
        case .sui:
            return try SuiAddress(publicKey: privateKey.publicKey, curve: curve).string
        default:
            throw Error.notImplemented
        }
    }
}
