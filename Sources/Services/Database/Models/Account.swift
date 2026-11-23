//
//  Account.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 28.12.25.
//  Copyright © 2025 Reefr Wallet. All rights reserved.
//

import SwiftData
import WalletKit

// MARK: - Account

struct Account: Equatable, Hashable, Identifiable, Sendable {
    var id: PersistentIdentifier?

    let address: String
    let blockchain: Blockchain
    let derivationPath: DerivationPath?
    let keyStoreId: PersistentIdentifier
    let name: String
    /// The raw public key, kept where the address is a hash of it and a first send needs it (TON).
    let publicKey: Data?
    let rpcURLOverride: URL?
    let signatureScheme: Curve?
    /// Which indexing backend a Bitcoin account talks to. `nil` means the
    /// network's default (Electrum). Set only at account creation — like
    /// `rpcURLOverride`, there is no edit-account flow for this yet.
    /// Meaningless for every other chain.
    let bitcoinBackend: BitcoinBackendKind?

    init(
        address: String,
        blockchain: Blockchain,
        derivationPath: DerivationPath?,
        keyStoreId: PersistentIdentifier,
        name: String,
        publicKey: Data? = nil,
        rpcURLOverride: URL? = nil,
        signatureScheme: Curve? = nil,
        bitcoinBackend: BitcoinBackendKind? = nil
    ) {
        id = nil

        self.address = address
        self.blockchain = blockchain
        self.derivationPath = derivationPath
        self.keyStoreId = keyStoreId
        self.name = name
        self.publicKey = publicKey
        self.rpcURLOverride = rpcURLOverride
        self.signatureScheme = signatureScheme
        self.bitcoinBackend = bitcoinBackend
    }
}

// MARK: - AccountModel

@Model
final class AccountModel {
    var address: String
    var derivationPath: String?
    var name: String
    var publicKey: Data?
    var rpcURLOverride: String?
    var signatureScheme: String?
    var bitcoinBackend: String?
    /// When Cardano receive-address discovery last succeeded; `nil` if it never has.
    var receiveAddressesObservedAt: Date?

    @Relationship(deleteRule: .cascade, inverse: \ReceiveAddressModel.account)
    var receiveAddresses: [ReceiveAddressModel] = []

    @Relationship(deleteRule: .cascade, inverse: \ApprovalModel.account)
    var approvals: [ApprovalModel] = []

    @Relationship(deleteRule: .cascade, inverse: \ApprovalScanModel.account)
    var approvalScans: [ApprovalScanModel] = []

    @Relationship(deleteRule: .cascade, inverse: \BalanceModel.account)
    var balances: [BalanceModel]

    @Relationship(deleteRule: .cascade, inverse: \DefiPositionModel.account)
    var defiPositions: [DefiPositionModel] = []

    @Relationship(deleteRule: .cascade, inverse: \NFTModel.account)
    var nfts: [NFTModel] = []

    @Relationship(deleteRule: .cascade, inverse: \NFTPendingSendModel.account)
    var nftPendingSends: [NFTPendingSendModel] = []

    @Relationship(deleteRule: .cascade, inverse: \NFTScanModel.account)
    var nftScans: [NFTScanModel] = []

    @Relationship(deleteRule: .cascade, inverse: \NFTTransferEventModel.account)
    var nftTransferEvents: [NFTTransferEventModel] = []

    @Relationship(deleteRule: .cascade, inverse: \StakingModel.account)
    var staking: StakingModel?

    @Relationship(deleteRule: .cascade, inverse: \WalletTransactionModel.account)
    var transactions: [WalletTransactionModel]

    @Relationship(deleteRule: .cascade, inverse: \WalletTransactionSyncStateModel.account)
    var transactionSyncState: WalletTransactionSyncStateModel?

    @Relationship(deleteRule: .noAction)
    var blockchain: BlockchainModel

    @Relationship(deleteRule: .noAction)
    var keyStore: KeyStoreModel

    init(
        address: String,
        blockchain: BlockchainModel,
        derivationPath: String? = nil,
        keyStore: KeyStoreModel,
        name: String,
        publicKey: Data? = nil,
        rpcURLOverride: URL? = nil,
        signatureScheme: Curve? = nil,
        bitcoinBackend: BitcoinBackendKind? = nil
    ) {
        guard derivationPath != nil || keyStore.isWatchOnly else {
            preconditionFailure("Missing derivation path")
        }

        self.address = address
        self.balances = []
        self.staking = nil
        self.transactions = []
        self.transactionSyncState = nil
        self.blockchain = blockchain
        self.derivationPath = derivationPath
        self.keyStore = keyStore
        self.name = name
        self.publicKey = publicKey
        self.rpcURLOverride = rpcURLOverride?.absoluteString
        self.signatureScheme = signatureScheme?.rawValue
        self.bitcoinBackend = bitcoinBackend?.rawValue
    }
}

// MARK: - Init

extension Account {
    init(model: AccountModel) throws {
        id = model.id
        address = model.address
        blockchain = model.blockchain.blockchain
        derivationPath = try model.derivationPath.map { try DerivationPath(string: $0) }
        keyStoreId = model.keyStore.id
        name = model.name
        publicKey = model.publicKey

        if let signatureScheme = model.signatureScheme {
            self.signatureScheme = Curve(rawValue: signatureScheme)
        } else {
            self.signatureScheme = nil
        }

        if let rpcURLOverride = model.rpcURLOverride {
            self.rpcURLOverride = URL(string: rpcURLOverride)
        } else {
            self.rpcURLOverride = nil
        }

        if let bitcoinBackend = model.bitcoinBackend {
            self.bitcoinBackend = BitcoinBackendKind(rawValue: bitcoinBackend)
        } else {
            self.bitcoinBackend = nil
        }
    }
}

extension AccountModel {
    convenience init(account: Account, blockchain: BlockchainModel, keyStore: KeyStoreModel) throws {
        self.init(
            address: account.address,
            blockchain: blockchain,
            derivationPath: account.derivationPath?.string,
            keyStore: keyStore,
            name: account.name,
            publicKey: account.publicKey,
            rpcURLOverride: account.rpcURLOverride,
            signatureScheme: account.signatureScheme,
            bitcoinBackend: account.bitcoinBackend
        )
    }
}

// MARK: - Comparable

private extension AccountModel {
    var parsedDerivationPath: DerivationPath? {
        derivationPath.flatMap { try? DerivationPath(string: $0) }
    }
}

extension AccountModel: Comparable {
    static func < (lhs: AccountModel, rhs: AccountModel) -> Bool {
        let lhsName = lhs.blockchain.blockchain.displayName
        let rhsName = rhs.blockchain.blockchain.displayName

        guard lhsName == rhsName else {
            return lhsName < rhsName
        }

        // Accounts without a path (watch-only) go last, by name.
        switch (lhs.parsedDerivationPath, rhs.parsedDerivationPath) {
        case let (lhsPath?, rhsPath?): return lhsPath < rhsPath
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil): return lhs.name < rhs.name
        }
    }
}

extension AccountModel {
    /// Sums every balance belonging to the account, plus its staked amount, faulting in each
    /// balance's `TokenModel` relationship along the way. A method, not a
    /// property, so call sites don't treat it as a cheap accessor — calling
    /// it once per balance in the account (instead of once per account)
    /// turns an O(N) sum into an O(N²) fault storm.
    /// Visible balances, staked funds and DeFi positions.
    func usdValue() -> Decimal {
        let defi = defiPositions.reduce(0) { $0 + $1.usdValue }

        return balances.reduce(into: (staking?.stakedUSDValue ?? 0) + defi) { partialResult, balance in
            // Unidentified tokens keep any stale price but don't count.
            if !balance.token.isHidden {
                partialResult += balance.usdValue
            }
        }
    }
}
