import BigInt
import Foundation
import SwiftData
import SwiftUI
import WalletKit

final class BalancesService {
    @AppStorage("MoralisAPIKey") private var moralisAPIKey: String?
    @AppStorage("ProxyHost") private var proxyHost: String = ""
    @AppStorage("ProxyPort") private var proxyPort: Int = 0
    @AppStorage("UseProxy") private var useProxy: Bool = false

    private lazy var clientProvider = DI.injectOrFail(BlockchainClientProvider.self)
    private let databaseService: DatabaseService

    init(databaseService: DatabaseService? = nil) {
        self.databaseService = databaseService ?? DI.injectOrFail(DatabaseService.self)
    }

    func usdValue(accountId: PersistentIdentifier) async throws -> Decimal {
        let balances = try await databaseService.fetchBalances(accountId: accountId)

        guard !balances.isEmpty else {
            return 0
        }

        return balances.reduce(into: 0) { partialResult, balance in
            partialResult += (balance.token.usdPrice ?? 0) * balance.decimalAmount
        }
    }

    func usdValue(keyStoreId: PersistentIdentifier) async throws -> Decimal {
        var result: Decimal = 0

        guard let keyStore = try await databaseService.fetchKeyStore(id: keyStoreId) else {
            throw Error.notFound
        }

        for account in keyStore.accounts {
            guard let accountId = account.id else {
                throw Error.invalidData
            }

            try await result += usdValue(accountId: accountId)
        }

        return result
    }

    @MainActor
    func updateBalances(_ account: Account) async throws {
        let client = try clientProvider.getClient(
            blockchain: account.blockchain,
            rpcURL: account.rpcURLOverride
        )

        let storedTokens = try await databaseService.fetchTokens(blockchain: account.blockchain)

        let balances: [Balance]
        if client.isSupported(.allBalances) {
            balances = try await fetchAllBalances(client: client, account: account, storedTokens: storedTokens)
        } else {
            balances = try await fetchBalancesPerToken(client: client, account: account, storedTokens: storedTokens)
        }

        try await databaseService.updateBalances(account: account, updates: balances)
    }
}

private extension BalancesService {
    func fetchAllBalances(
        client: AnyBlockchainClient,
        account: Account,
        storedTokens: [Token]
    ) async throws -> [Balance] {
        var balances: [Balance] = []

        for (tokenAddress, amount) in try await client.getAllBalances(account.address) {
            if var token = storedTokens.first(where: { $0.address == tokenAddress }) {
                if let price = try? await client.getTokenPrice(tokenAddress) {
                    token.usdPrice = price
                }

                balances.append(try await makeBalance(account: account, amount: amount, token: token))
            } else {
                // get info + price and save new token record
                let tokenInfo = try await client.getTokenInfo(tokenAddress)

                let token = Token(
                    address: tokenAddress,
                    blockchain: account.blockchain,
                    decimalsCount: tokenInfo.decimals,
                    imageURL: nil,
                    isHidden: false,
                    isIncludedInBalance: true,
                    isNativeToken: false,
                    name: tokenInfo.name,
                    symbol: tokenInfo.symbol,
                    usdPrice: try? await client.getTokenPrice(tokenAddress)
                )

                balances.append(try await makeBalance(account: account, amount: amount, token: token))
            }
        }

        return balances
    }

    func fetchBalancesPerToken(
        client: AnyBlockchainClient,
        account: Account,
        storedTokens: [Token]
    ) async throws -> [Balance] {
        let allTokens = storedTokens + (try readConfiguredTokens(blockchain: account.blockchain)
            .filter { token in
                !storedTokens.contains { $0.address == token.address }
            })

        let tokenAddresses = try allTokens.compactMap { token -> String? in
            guard !token.isNativeToken else { return nil }
            guard let address = token.address else { throw Error.invalidData }
            return address
        }

        let bulkBalances: [String: BigUInt]
        if client.isSupported(.multipleBalances) {
            bulkBalances = try await client.getBalances(account.address, tokens: tokenAddresses)
        } else {
            bulkBalances = [:]
        }

        var balances: [Balance] = []

        for var token in allTokens {
            let amount: BigUInt = if token.isNativeToken {
                try await client.getNativeBalance(account.address)
            } else if let address = token.address {
                if let amount = bulkBalances[address] {
                    amount
                } else {
                    try await client.getBalance(account.address, token: address)
                }
            } else {
                throw Error.invalidData
            }

            if !storedTokens.contains(where: { $0.address == token.address }) {
                let tokenInfo = try await client.getTokenInfo(token.address)
                token.decimalsCount = tokenInfo.decimals
                token.name = tokenInfo.name
                token.symbol = tokenInfo.symbol
            }

            if let price = try? await client.getTokenPrice(token.address) {
                token.usdPrice = price
            }

            let balance = try await makeBalance(account: account, amount: amount, token: token)

            if balance.amount.isZero, !storedTokens.contains(where: { $0.address == token.address }) {
                continue
            }

            balances.append(balance)
        }

        return balances
    }
}

private extension BalancesService {
    // { "chainId": { "symbol": "address", ... }}
    typealias ERC20Configuration = [String: [String: String]]

    func makeBalance(account: Account, amount: BigUInt, token: Token) async throws -> Balance {
        let decimalAmount = Decimal(
            sign: .plus,
            exponent: -Int(token.decimalsCount),
            significand: Decimal(amount)
        )

        return Balance(
            account: account,
            amount: amount,
            token: token,
            usdValue: token.usdPrice.map { $0 * decimalAmount }
        )
    }

    func readConfiguredTokens(blockchain: WKBlockchain) throws -> [Token] {
        guard let configURL = Bundle.module.url(forResource: "erc20", withExtension: "json") else {
            throw Error.notFound
        }

        guard case let .evm(chain) = blockchain else {
            throw Error.internalError
        }

        let jsonData = try Data(contentsOf: configURL)
        let config = try JSONDecoder().decode(ERC20Configuration.self, from: jsonData)
        let tokens = config["0x\(String(chain.chainId, radix: 16))"] ?? [:]

        return tokens.keys.map {
            Token(
                address: tokens[$0],
                blockchain: blockchain,
                decimalsCount: 0,
                imageURL: nil,
                isHidden: false,
                isIncludedInBalance: nil,
                isNativeToken: false,
                name: $0,
                symbol: $0,
                usdPrice: nil
            )
        }
    }
}
