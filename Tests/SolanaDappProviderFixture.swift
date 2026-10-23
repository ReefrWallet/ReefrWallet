import Foundation
import WalletKit
import WalletKitTesting
@testable import ReefrWallet

struct SolanaDappProviderFixture {
    let databaseService: DatabaseService
    let provider: SolanaDappProvider
    let session: DappSession
    let signingService: DappSigningService
    let account: ReefrWallet.Account
    let keyStore: KeyStore
    let origin = "https://dapp.example"

    static func make() async throws -> SolanaDappProviderFixture {
        let databaseService = try makeDatabaseService()
        let accountService = AccountService(databaseService: databaseService)
        let transactionService = TransactionService(databaseService: databaseService)
        let clientProvider = BlockchainClientProvider()

        let keyStore = try await makeLocalKeyStore(
            databaseService: databaseService,
            name: "Solana Local Test Key Store"
        )

        let account = try await accountService.makeAccount(.solana(.devnet), keyStore: keyStore)

        let provider = SolanaDappProvider(clientProvider: clientProvider, transactionService: transactionService)

        let session = DappSession(origin: "https://dapp.example")
        await session.setActiveAccount(account)

        return SolanaDappProviderFixture(
            databaseService: databaseService,
            provider: provider,
            session: session,
            signingService: DappSigningService(transactionService: transactionService),
            account: account,
            keyStore: keyStore
        )
    }

    func context(approving: any DappApproving) -> DappRequestContext {
        DappRequestContext(origin: origin, session: session, approving: approving, signingService: signingService)
    }

    var accountAddress: SolanaAddress {
        get throws { try SolanaAddress(string: account.address) }
    }

    /// A legacy message's raw bytes (no signature vector) — every count
    /// used here is small enough (< 128) that Solana's compact-u16
    /// length prefix is always exactly one byte equal to the count, so
    /// this doesn't need WalletKit's own (internal) shortvec encoder.
    func legacyMessageBytes(
        staticAccountKeys: [SolanaAddress],
        numRequiredSignatures: Int,
        numReadonlySignedAccounts: Int = 0,
        numReadonlyUnsignedAccounts: Int = 0
    ) -> Data {
        var data = Data([
            UInt8(numRequiredSignatures),
            UInt8(numReadonlySignedAccounts),
            UInt8(numReadonlyUnsignedAccounts)
        ])
        data.append(UInt8(staticAccountKeys.count))
        for key in staticAccountKeys {
            data.append(key.rawBytes)
        }

        data.append(Data(repeating: 9, count: 32)) // recentBlockhash
        data.append(0) // zero instructions
        return data
    }

    /// A version-0 message's raw bytes (no signature vector, no
    /// instructions, no address-table lookups) — just enough to be a
    /// structurally valid v0 message for the `signMessage` safety-check
    /// tests.
    func v0MessageBytes(staticAccountKeys: [SolanaAddress], numRequiredSignatures: Int) -> Data {
        var data = Data([0x80])
        data.append(contentsOf: [UInt8(numRequiredSignatures), 0, 0])
        data.append(UInt8(staticAccountKeys.count))
        for key in staticAccountKeys {
            data.append(key.rawBytes)
        }

        data.append(Data(repeating: 9, count: 32)) // recentBlockhash
        data.append(0) // zero instructions
        data.append(0) // zero address-table lookups
        return data
    }

    func wrapTransaction(messageBytes: Data, signatures: [Data]) -> Data {
        var tx = Data([UInt8(signatures.count)])
        for signature in signatures {
            tx.append(signature)
        }

        tx.append(messageBytes)
        return tx
    }

    /// Re-derives `account`'s signer directly from the key store's seed,
    /// independently of the dapp-provider path — mirrors
    /// `SuiDappProviderFixture.makeIndependentSigner()`.
    func makeIndependentSigner() throws -> SolanaPKeySigner {
        guard let derivationPath = account.derivationPath, case let .solana(network) = account.blockchain else {
            throw ReefrError.invalidData
        }

        let seed = try Seed(rawBytes: try keyStore.plainSeed())
        let privateKey = try seed.masterKey(curve: .ed25519).derive(derivationPath).privateKey()
        return try SolanaPKeySigner(network: network, privateKey: privateKey, derivationPath: derivationPath)
    }
}
