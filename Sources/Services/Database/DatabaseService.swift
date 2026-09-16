import Foundation
import SwiftData
import WalletKit

@ModelActor
actor DatabaseService {
    func deleteAccount(id: PersistentIdentifier) throws {
        let predicate = #Predicate<AccountModel> { $0.id == id }
        guard let account = try modelContext.fetch(FetchDescriptor(predicate: predicate)).first else {
            throw Error.notFound
        }

        modelContext.delete(account)
        try modelContext.save()
    }

    #if DEBUG
    /// Deletes all accounts across every key store, keeping the key stores themselves.
    func deleteAllAccounts() throws {
        for account in try modelContext.fetch(FetchDescriptor<AccountModel>()) {
            modelContext.delete(account)
        }

        for blockchain in try modelExecutor.modelContext.fetch(FetchDescriptor<BlockchainModel>()) {
            modelContext.delete(blockchain)
        }

        try modelContext.save()
    }

    /// Deletes all balances across every account, keeping the tokens themselves.
    func deleteAllBalances() throws {
        for balance in try modelContext.fetch(FetchDescriptor<BalanceModel>()) {
            modelContext.delete(balance)
        }

        try modelContext.save()
    }

    /// Deletes all non-native tokens on every blockchain, keeping each blockchain's mandatory
    /// native token intact. This respectively deletes all balances from all accounts.
    func deleteAllTokens() throws {
        for balance in try modelContext.fetch(FetchDescriptor<BalanceModel>()) {
            modelContext.delete(balance)
        }

        let predicate = #Predicate<TokenModel> { !$0.isNativeToken }
        for token in try modelContext.fetch(FetchDescriptor(predicate: predicate)) {
            modelContext.delete(token)
        }

        try modelContext.save()
    }
    #endif

    func deleteKeyStore(id: PersistentIdentifier) throws {
        let predicate = #Predicate<KeyStoreModel> { $0.id == id }
        try modelContext.delete(model: KeyStoreModel.self, where: predicate)
        try modelContext.save()
    }

    func fetchAccount(id: PersistentIdentifier) throws -> Account? {
        let predicate = #Predicate<AccountModel> { $0.id == id }
        let models = try modelContext.fetch(FetchDescriptor(predicate: predicate))
        return try models.first.map { try Account(model: $0) }
    }

    func fetchAccounts(
        keyStoreId: PersistentIdentifier,
        blockchain: WKBlockchain? = nil
    ) throws -> [Account] {
        let serializedBlockchain = try blockchain?.asJSONString()
        let predicate: Predicate<AccountModel>

        if let serializedBlockchain {
            predicate = #Predicate<AccountModel> {
                $0.keyStore.id == keyStoreId && $0.blockchain.serialized == serializedBlockchain
            }
        } else {
            predicate = #Predicate<AccountModel> {
                $0.keyStore.id == keyStoreId
            }
        }

        return try modelContext.fetch(FetchDescriptor(predicate: predicate)).map { try Account(model: $0) }
    }

    func fetchBalance(account: Account, token: Token) throws -> Balance? {
        guard let accountId = account.id else {
            throw Error.invalidData
        }

        let tokenAddress = token.address
        let predicate = #Predicate<BalanceModel> {
            $0.account.id == accountId && $0.token.address == tokenAddress
        }
        let models = try modelContext.fetch(FetchDescriptor(predicate: predicate))
        return try models.first.map(Balance.init(model:))
    }

    func fetchBalances(accountId: PersistentIdentifier) throws -> [Balance] {
        let predicate = #Predicate<BalanceModel> { $0.account.id == accountId }
        let models = try modelContext.fetch(FetchDescriptor(predicate: predicate))
        return try models.map(Balance.init(model:))
    }

    func fetchKeyStore(id: PersistentIdentifier) throws -> KeyStore? {
        let predicate = #Predicate<KeyStoreModel> { $0.id == id }
        let models = try modelContext.fetch(FetchDescriptor(predicate: predicate))
        return try models.first.map(KeyStore.init(model:))
    }

    func fetchToken(tokenAddress: String, blockchain: WKBlockchain) throws -> Token? {
        let serializedBlockchain = try blockchain.asJSONString()
        let predicate = #Predicate<TokenModel> { token in
            if let address = token.address {
                return token.blockchain?.serialized == serializedBlockchain
                && tokenAddress == address
            } else {
                return false
            }
        }

        return try modelContext.fetch(FetchDescriptor(predicate: predicate)).first.map(Token.init(model:))
    }

    func fetchTokens(account: Account) throws -> [Token] {
        guard let accountId = account.id else {
            throw Error.invalidData
        }

        let predicate = #Predicate<AccountModel> { $0.id == accountId }

        guard let accountModel = try modelContext.fetch(FetchDescriptor(predicate: predicate)).first else {
            throw Error.notFound
        }

        return accountModel.balances.map { Token(model: $0.token) }
    }

    func fetchTokens(blockchain: WKBlockchain) throws -> [Token] {
        let serializedBlockchain = try blockchain.asJSONString()
        let predicate = #Predicate<TokenModel> { $0.blockchain?.serialized == serializedBlockchain }
        return try modelContext.fetch(FetchDescriptor(predicate: predicate)).map(Token.init(model:))
    }

    @discardableResult
    func insertAccount(_ account: Account, keyStore: KeyStore) throws -> Account {
        guard let keyStoreId = keyStore.id else {
            throw Error.invalidData
        }

        let keyStorePredicate = #Predicate<KeyStoreModel> { $0.id == keyStoreId }
        guard let keyStore = try modelContext.fetch(FetchDescriptor(predicate: keyStorePredicate)).first else {
            throw Error.notFound
        }

        let serializedBlockchain = try account.blockchain.asJSONString()
        let blockchainPredicate = #Predicate<BlockchainModel> { $0.serialized == serializedBlockchain }
        var blockchain = try modelContext.fetch(FetchDescriptor(predicate: blockchainPredicate)).first

        if blockchain == nil {
            blockchain = try BlockchainModel(blockchain: account.blockchain)
        }

        let model = try AccountModel(account: account, blockchain: blockchain!, keyStore: keyStore)
        modelContext.insert(model)
        try modelContext.save()

        var account = account
        account.id = model.persistentModelID
        return account
    }

    @discardableResult
    func insertBlockchain(_ blockchain: WKBlockchain) throws -> PersistentIdentifier {
        let serializedBlockchain = try blockchain.asJSONString()
        let predicate = #Predicate<BlockchainModel> { $0.serialized == serializedBlockchain }
        guard try modelContext.fetch(FetchDescriptor(predicate: predicate)).isEmpty else {
            throw Error.alreadyExists
        }

        let model = try BlockchainModel(blockchain: blockchain)
        modelContext.insert(model)
        try modelContext.save()
        return model.persistentModelID
    }

    @discardableResult
    func insertKeyStore(_ keyStore: KeyStore) throws -> PersistentIdentifier {
        let model = KeyStoreModel(from: keyStore)
        modelContext.insert(model)
        try modelContext.save()
        return model.persistentModelID
    }

    @discardableResult
    func insertToken(_ token: Token, blockchain: WKBlockchain) throws -> PersistentIdentifier {
        let serializedBlockchain = try blockchain.asJSONString()
        let predicate = #Predicate<BlockchainModel> { $0.serialized == serializedBlockchain }
        let blockchainModel = try modelContext.fetch(FetchDescriptor(predicate: predicate)).first

        let tokenModel = TokenModel(from: token)
        tokenModel.blockchain = blockchainModel
        tokenModel.imageURL = token.imageURL
        tokenModel.isIncludedInBalance = token.isIncludedInBalance
        tokenModel.usdPrice = token.usdPrice

        modelContext.insert(tokenModel)
        try modelContext.save()
        return tokenModel.persistentModelID
    }

    func renameAccount(id: PersistentIdentifier, name: String) throws {
        let predicate = #Predicate<AccountModel> { $0.id == id }

        guard let account = try modelContext.fetch(FetchDescriptor(predicate: predicate)).first else {
            throw Error.notFound
        }

        account.name = name
        try modelContext.save()
    }

    func renameKeyStore(id: PersistentIdentifier, name: String) throws {
        let predicate = #Predicate<KeyStoreModel> { $0.id == id }
        guard let keyStore = try modelContext.fetch(FetchDescriptor(predicate: predicate)).first else {
            throw Error.notFound
        }

        keyStore.name = name
        try modelContext.save()
    }

    @discardableResult
    func saveBalance(_ balance: Balance) throws -> PersistentIdentifier {
        try saveBalance(balance, shouldSaveContext: true)
    }

    func saveBalances(_ balances: [Balance]) throws {
        for balance in balances {
            try saveBalance(balance, shouldSaveContext: false)
        }

        try modelContext.save()
    }

    func updateBalances(account: Account, updates: [Balance]) throws {
        guard let accountId = account.id else {
            throw Error.invalidData
        }

        guard let account = try fetchAccount(id: accountId) else {
            throw Error.notFound
        }

        var balances = try fetchBalances(accountId: accountId)
        var tokens = try fetchTokens(blockchain: account.blockchain)

        for update in updates {
            let token: Token

            if var existing = tokens.first(where: { $0.address == update.token.address }) {
                existing.usdPrice = update.token.usdPrice ?? existing.usdPrice
                token = existing
            } else {
                try insertToken(update.token, blockchain: account.blockchain)
                tokens.append(update.token)
                token = update.token
            }

            if let index = balances.firstIndex(where: { $0.token.address == update.token.address }) {
                balances[index] = Balance(
                    account: account,
                    amount: update.amount,
                    token: token,
                    usdValue: update.usdValue
                )
            } else {
                balances.append(Balance(
                    account: account,
                    amount: update.amount,
                    token: token,
                    usdValue: update.usdValue
                ))
            }
        }

        try saveBalances(balances)
    }

    func updateTokenPrices(_ tokens: [Token]) throws {
        for token in tokens {
            try updateTokenPrice(token, shouldSaveContext: false)
        }

        try modelContext.save()
    }

    func usdValue(accountId: PersistentIdentifier) throws -> Decimal {
        let predicate = #Predicate<AccountModel> { $0.id == accountId }
        guard let accountModel = try modelContext.fetch(FetchDescriptor(predicate: predicate)).first else {
            throw Error.notFound
        }

        return accountModel.usdValue()
    }

    func usdValue(keyStoreId: PersistentIdentifier) throws -> Decimal {
        let predicate = #Predicate<KeyStoreModel> { $0.id == keyStoreId }
        guard let keyStoreModel = try modelContext.fetch(FetchDescriptor(predicate: predicate)).first else {
            throw Error.notFound
        }

        return keyStoreModel.accounts.reduce(into: 0) { $0 += $1.usdValue() }
    }

    func watchOnlyKeyStore() throws -> KeyStore {
        let rawKind = KeyStore.Kind.watchOnly.rawValue
        let predicate = #Predicate<KeyStoreModel> { $0.rawKind == rawKind }

        if let model = try modelContext.fetch(FetchDescriptor(predicate: predicate)).first {
            return try KeyStore(model: model)
        }

        let model = KeyStoreModel(.watchOnly, name: "Watch-Only")
        modelContext.insert(model)
        try modelContext.save()

        return try KeyStore(model: model)
    }
}

private extension DatabaseService {
    @discardableResult
    func saveBalance(_ balance: Balance, shouldSaveContext: Bool) throws -> PersistentIdentifier {
        guard let accountId = balance.account.id else {
            throw Error.invalidData
        }

        let accountPredicate = #Predicate<AccountModel> { $0.id == accountId }
        guard let accountModel = try modelContext.fetch(FetchDescriptor(predicate: accountPredicate)).first else {
            throw Error.notFound
        }

        let serializedBlockchain = try balance.account.blockchain.asJSONString()
        let tokenAddress = balance.token.address
        let tokenPredicate = #Predicate<TokenModel> {
            $0.blockchain?.serialized == serializedBlockchain && $0.address == tokenAddress
        }

        guard let tokenModel = try modelContext.fetch(FetchDescriptor(predicate: tokenPredicate)).first else {
            throw Error.notFound
        }

        tokenModel.decimalsCount = balance.token.decimalsCount
        tokenModel.imageURL = balance.token.imageURL
        tokenModel.isIncludedInBalance = balance.token.isIncludedInBalance
        tokenModel.isNativeToken = balance.token.isNativeToken
        tokenModel.name = balance.token.name
        tokenModel.symbol = balance.token.symbol
        tokenModel.usdPrice = balance.token.usdPrice

        let balanceModel: BalanceModel

        if let balanceId = balance.id {
            let balancePredicate = #Predicate<BalanceModel> { $0.id == balanceId }
            balanceModel = try modelContext.fetch(FetchDescriptor(predicate: balancePredicate)).first
            ?? BalanceModel(account: accountModel, amount: balance.amount, token: tokenModel)
        } else {
            let balancePredicate = #Predicate<BalanceModel> {
                $0.account.id == accountId && $0.token.address == tokenAddress
            }
            balanceModel = try modelContext.fetch(FetchDescriptor(predicate: balancePredicate)).first
            ?? BalanceModel(account: accountModel, amount: balance.amount, token: tokenModel)
        }

        balanceModel.account = accountModel
        balanceModel.amount = balance.amount
        balanceModel.token = tokenModel

        if balanceModel.modelContext == nil {
            modelContext.insert(balanceModel)
        }

        if shouldSaveContext {
            try modelContext.save()
        }

        return balanceModel.persistentModelID
    }

    @discardableResult
    func updateTokenPrice(_ token: Token, shouldSaveContext: Bool) throws -> PersistentIdentifier {
        guard let blockchain = token.blockchain else {
            throw Error.invalidData
        }

        let serializedBlockchain = try blockchain.asJSONString()
        let tokenAddress = token.address
        let predicate = #Predicate<TokenModel> {
            $0.blockchain?.serialized == serializedBlockchain && $0.address == tokenAddress
        }

        guard let tokenModel = try modelContext.fetch(FetchDescriptor(predicate: predicate)).first else {
            throw Error.notFound
        }

        tokenModel.usdPrice = token.usdPrice

        if shouldSaveContext {
            try modelContext.save()
        }

        return tokenModel.persistentModelID
    }
}
