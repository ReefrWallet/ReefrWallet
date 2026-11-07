import Foundation
import Testing
import WalletKit
@testable import ReefrWallet

private struct ChainCase: CustomTestStringConvertible, Sendable {
    let blockchain: Blockchain
    var curve: Curve?
    var scriptType: BitcoinScriptType?
    let first: String
    let second: String

    var testDescription: String { "\(blockchain.displayName) \(first)" }
}

private let chainCases: [ChainCase] = [
    ChainCase(
        blockchain: .aptos(.mainnet), curve: .ed25519,
        first: "m/44'/637'/0'/0'/0'", second: "m/44'/637'/1'/0'/0'"
    ),
    ChainCase(
        blockchain: .aptos(.testnet), curve: .secp256k1,
        first: "m/44'/637'/0'/0/0", second: "m/44'/637'/1'/0/0"
    ),
    ChainCase(
        blockchain: .bitcoin(.mainnet), scriptType: .p2wpkh,
        first: "m/84'/0'/0'", second: "m/84'/0'/1'"
    ),
    ChainCase(
        blockchain: .bitcoin(.testnet), scriptType: .p2tr,
        first: "m/86'/1'/0'", second: "m/86'/1'/1'"
    ),
    ChainCase(
        blockchain: .cardano(.preprod), curve: .ed25519,
        first: "m/1852'/1815'/0'", second: "m/1852'/1815'/1'"
    ),
    ChainCase(
        blockchain: .evm(.custom(31_337)), curve: .secp256k1,
        first: "m/44'/60'/0'/0/0", second: "m/44'/60'/0'/0/1"
    ),
    ChainCase(
        blockchain: .evm(.ethereum(.mainnet)), curve: .secp256k1,
        first: "m/44'/60'/0'/0/0", second: "m/44'/60'/0'/0/1"
    ),
    ChainCase(
        blockchain: .evm(.ethereum(.sepolia)), curve: .secp256k1,
        first: "m/44'/60'/0'/0/0", second: "m/44'/60'/0'/0/1"
    ),
    ChainCase(
        blockchain: .solana(.devnet), curve: .ed25519,
        first: "m/44'/501'/0'/0'", second: "m/44'/501'/1'/0'"
    ),
    ChainCase(
        blockchain: .sui(.mainnet), curve: .ed25519,
        first: "m/44'/784'/0'/0'/0'", second: "m/44'/784'/0'/0'/1'"
    ),
    ChainCase(
        blockchain: .sui(.testnet), curve: .secp256k1,
        first: "m/54'/784'/0'/0'/0'", second: "m/54'/784'/0'/0'/1'"
    ),
    ChainCase(
        blockchain: .tron(.testnet), curve: .secp256k1,
        first: "m/44'/195'/0'/0/0", second: "m/44'/195'/0'/0/1"
    )
]

/// How "Add Account" picks the next default derivation path.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct NextDerivationPathTests {
    private static let ethereum = Blockchain.evm(.ethereum(.mainnet))
    private static let offlineRpcURL = URL(string: "http://127.0.0.1:1")!
    private static let sepolia = Blockchain.evm(.ethereum(.sepolia))

    private let accountService: AccountService
    private let databaseService: DatabaseService
    private let keyStore: KeyStore

    init() async throws {
        databaseService = try makeDatabaseService()
        accountService = AccountService(databaseService: databaseService)
        keyStore = try await makeLocalKeyStore(databaseService: databaseService)
    }

    private func next(
        _ blockchain: Blockchain,
        keyStore: KeyStore? = nil,
        curve: Curve? = nil,
        scriptType: BitcoinScriptType? = nil
    ) async -> String? {
        await accountService.nextDerivationPath(
            blockchain,
            keyStore: keyStore ?? self.keyStore,
            signatureScheme: curve,
            bitcoinScriptType: scriptType
        )?.string
    }

    private func seed(
        _ blockchain: Blockchain,
        path: String?,
        keyStore: KeyStore? = nil,
        curve: Curve? = nil
    ) async throws {
        let keyStore = keyStore ?? self.keyStore
        let keyStoreId = try #require(keyStore.id)

        _ = try await databaseService.insertAccount(
            ReefrWallet.Account(
                address: "\(blockchain.displayName) \(path ?? UUID().uuidString)",
                blockchain: blockchain,
                derivationPath: try path.map { try DerivationPath(string: $0) },
                keyStoreId: keyStoreId,
                name: "Seeded",
                rpcURLOverride: nil,
                signatureScheme: curve
            ),
            keyStore: keyStore
        )
    }

    // MARK: Numbering

    @Test(arguments: chainCases)
    fileprivate func theFirstAccountUsesIndexZero(_ chain: ChainCase) async {
        #expect(await next(chain.blockchain, curve: chain.curve, scriptType: chain.scriptType) == chain.first)
    }

    @Test(arguments: chainCases)
    fileprivate func theNextAccountFollowsTheExistingOne(_ chain: ChainCase) async throws {
        try await seed(chain.blockchain, path: chain.first, curve: chain.curve)

        #expect(await next(chain.blockchain, curve: chain.curve, scriptType: chain.scriptType) == chain.second)
    }

    @Test func aGapIsNotReused() async throws {
        try await seed(Self.sepolia, path: "m/44'/60'/0'/0/0")
        try await seed(Self.sepolia, path: "m/44'/60'/0'/0/4")

        #expect(await next(Self.sepolia) == "m/44'/60'/0'/0/5")
    }

    @Test func numberingComparesIndicesNotPathStrings() async throws {
        for index in 0 ... 10 {
            try await seed(Self.sepolia, path: "m/44'/60'/0'/0/\(index)")
        }

        #expect(await next(Self.sepolia) == "m/44'/60'/0'/0/11")
    }

    // MARK: Scope

    @Test func networksOfOneChainAreNumberedSeparately() async throws {
        try await seed(Self.ethereum, path: "m/44'/60'/0'/0/0")
        try await seed(Self.ethereum, path: "m/44'/60'/0'/0/1")
        try await seed(Self.sepolia, path: "m/44'/60'/0'/0/0")

        #expect(await next(Self.ethereum) == "m/44'/60'/0'/0/2")
        #expect(await next(Self.sepolia) == "m/44'/60'/0'/0/1")
        #expect(await next(.evm(.base(.mainnet))) == "m/44'/60'/0'/0/0")
    }

    @Test func keyStoresAreNumberedSeparately() async throws {
        let other = try await makeLocalKeyStore(databaseService: databaseService, name: "Other")

        try await seed(Self.sepolia, path: "m/44'/60'/0'/0/0", keyStore: other)

        #expect(await next(Self.sepolia) == "m/44'/60'/0'/0/0")
        #expect(await next(Self.sepolia, keyStore: other) == "m/44'/60'/0'/0/1")
    }

    // MARK: Non-default paths

    @Test func customPathsAreNotCounted() async throws {
        try await seed(Self.sepolia, path: "m/44'/60'/7'/0/0")
        try await seed(Self.sepolia, path: "m/44'/60'/0'/1/9")

        #expect(await next(Self.sepolia) == "m/44'/60'/0'/0/0")
    }

    @Test func watchOnlyAccountsAreNotCounted() async throws {
        let watchOnly = try await makeWatchOnlyKeyStore(databaseService: databaseService)

        try await seed(Self.sepolia, path: nil, keyStore: watchOnly)

        #expect(await next(Self.sepolia, keyStore: watchOnly) == "m/44'/60'/0'/0/0")
    }

    // MARK: Shared numbering

    @Test func bitcoinScriptTypesShareNumbering() async throws {
        try await seed(.bitcoin(.mainnet), path: "m/84'/0'/0'")

        #expect(await next(.bitcoin(.mainnet), scriptType: .p2tr) == "m/86'/0'/1'")
    }

    @Test func suiKeySchemesShareNumbering() async throws {
        try await seed(.sui(.mainnet), path: "m/44'/784'/0'/0'/0'", curve: .ed25519)

        #expect(await next(.sui(.mainnet), curve: .secp256k1) == "m/54'/784'/0'/0'/1'")
    }

    // MARK: makeAccount

    @Test func accountsAddedWithoutAPathAdvanceTheIndex() async throws {
        let first = try await accountService.makeAccount(
            Self.sepolia,
            keyStore: keyStore,
            rpcURLOverride: Self.offlineRpcURL
        )

        let second = try await accountService.makeAccount(
            Self.sepolia,
            keyStore: keyStore,
            rpcURLOverride: Self.offlineRpcURL
        )

        #expect(first.derivationPath?.string == "m/44'/60'/0'/0/0")
        #expect(second.derivationPath?.string == "m/44'/60'/0'/0/1")
        #expect(first.name == "\(Self.sepolia.networkName) #1")
        #expect(second.name == "\(Self.sepolia.networkName) #2")
        #expect(first.address != second.address)
    }

    @Test func aPathAlreadyOnTheNetworkIsRejected() async throws {
        let path = try DerivationPath(string: "m/44'/60'/0'/0/0")

        try await accountService.makeAccount(
            Self.sepolia,
            keyStore: keyStore,
            rpcURLOverride: Self.offlineRpcURL,
            derivationPath: path
        )

        await #expect(throws: ReefrError.alreadyExists) {
            try await accountService.makeAccount(
                Self.sepolia,
                keyStore: keyStore,
                rpcURLOverride: Self.offlineRpcURL,
                derivationPath: path
            )
        }
    }

    /// Adds twice the way the popup does with Ethereum picked and Sepolia as its network.
    @Test func thePopupAdvancesOnTheSelectedNetwork() async throws {
        for expected in ["m/44'/60'/0'/0/0", "m/44'/60'/0'/0/1"] {
            let target = try #require(Self.ethereum.accountTarget(network: Self.sepolia, customChainId: "1"))
            let path = await accountService.nextDerivationPath(target, keyStore: keyStore)

            #expect(path?.string == expected)

            let account = try await accountService.makeAccount(
                target,
                keyStore: keyStore,
                rpcURLOverride: Self.offlineRpcURL,
                derivationPath: path
            )

            #expect(account.blockchain == Self.sepolia)
            #expect(account.derivationPath?.string == expected)
        }
    }

    // MARK: Popup target

    @Test func thePopupTargetsTheSelectedNetwork() {
        #expect(Self.ethereum.accountTarget(network: Self.sepolia, customChainId: "1") == Self.sepolia)
        #expect(Blockchain.bitcoin(.mainnet).accountTarget(network: .bitcoin(.signet), customChainId: "")
            == .bitcoin(.signet))
        #expect(Self.ethereum.accountTarget(network: nil, customChainId: "1") == nil)
    }

    @Test func thePopupTargetsTheTypedCustomChain() {
        let custom = Blockchain.evm(.custom(1))

        #expect(custom.accountTarget(network: custom, customChainId: "777") == .evm(.custom(777)))
        #expect(custom.accountTarget(network: custom, customChainId: "") == nil)
        #expect(custom.accountTarget(network: custom, customChainId: "abc") == nil)
    }
}
