import BigInt
import Foundation
import SwiftData
import SwiftUI
import WalletKit

final class BalancesService {
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

        if client.isSupported(.allBalances) {
            let balances = try await fetchAllBalances(client: client, account: account)
            try await databaseService.updateBalances(account: account, updates: balances)
        } else {
            let allTokens = try storedTokens + readConfiguredTokens(blockchain: account.blockchain)
                .filter { token in
                    !storedTokens.contains { $0.address == token.address }
                }

            let nativeBalance = try await fetchNativeBalance(
                client: client,
                account: account,
                storedTokens: storedTokens
            )

            try await databaseService.updateBalances(account: account, updates: [nativeBalance])

            try await updateTokenBalances(client: client, account: account, tokens: allTokens)
        }
    }
}

private extension BalancesService {
    func fetchAllBalances(
        client: AnyBlockchainClient,
        account: Account,
    ) async throws -> [Balance] {
        guard client.isSupported(.allBalances) else {
            throw Error.notSupported
        }

        var balances: [Balance] = []

        for (tokenAddress, amount) in try await client.getAllBalances(account.address) {
            if let token = try await databaseService.fetchToken(
                tokenAddress: tokenAddress,
                blockchain: account.blockchain
            ) {
                balances.append(try await makeBalance(account: account, amount: amount, token: token))
            } else {
                // get info and save new token record
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
                    usdPrice: nil
                )

                balances.append(try await makeBalance(account: account, amount: amount, token: token))
            }
        }

        return balances
    }

    func fetchNativeBalance(
        client: AnyBlockchainClient,
        account: Account,
        storedTokens: [Token]
    ) async throws -> Balance {
        let amount = try await client.getNativeBalance(account.address)

        let token: Token
        if let existing = storedTokens.first(where: { $0.isNativeToken }) {
            token = existing
        } else {
            let tokenInfo = try await client.getTokenInfo(nil)
            token = Token(
                address: nil,
                blockchain: account.blockchain,
                decimalsCount: tokenInfo.decimals,
                imageURL: nil,
                isHidden: false,
                isIncludedInBalance: true,
                isNativeToken: true,
                name: tokenInfo.name,
                symbol: tokenInfo.symbol,
                usdPrice: nil
            )
        }

        return try await makeBalance(account: account, amount: amount, token: token)
    }

    func updateBalances(account: Account, client: AnyBlockchainClient, tokens: [Token]) async throws {
        let balances = try await client.getBalances(
            account.address,
            tokens: tokens.map { $0.address ?? "" }
        )

        for (tokenAddress, amount) in balances {
            if let storedToken = try await databaseService.fetchToken(
                tokenAddress: tokenAddress,
                blockchain: account.blockchain
            ) {
                if var storedBalance: Balance = try await databaseService.fetchBalance(
                    account: account,
                    token: storedToken
                ) {
                    storedBalance.amount = amount
                    try await databaseService.saveBalance(storedBalance)
                } else {
                    let balance = Balance(
                        account: account,
                        amount: amount,
                        token: storedToken,
                        usdValue: nil
                    )
                    try await databaseService.saveBalance(balance)
                }
            } else {
                let tokenInfo = try await client.getTokenInfo(tokenAddress)
                let token = Token(
                    address: tokenAddress,
                    blockchain: account.blockchain,
                    decimalsCount: tokenInfo.decimals,
                    isHidden: false,
                    isNativeToken: false,
                    name: tokenInfo.name,
                    symbol: tokenInfo.symbol
                )
                try await databaseService.insertToken(token, blockchain: account.blockchain)

                let balance = Balance(
                    account: account,
                    amount: amount,
                    token: token,
                    usdValue: nil
                )
                try await databaseService.saveBalance(balance)
            }
        }
    }

    func updateTokenBalances(
        client: AnyBlockchainClient,
        account: Account,
        tokens: [Token]
    ) async throws {
        if client.isSupported(.multipleBalances) {
            printDebug("Requesting bulk balances for \(account.address)")
            var remainingTokens = tokens

            while !remainingTokens.isEmpty {
                let batch = Array(remainingTokens.prefix(20))

                Task.detached {
                    do {
                        try await self.updateBalances(account: account, client: client, tokens: batch)
                    } catch {
                        printError(error)
                    }
                }

                remainingTokens.removeFirst(batch.count)
            }
        } else {
            printDebug("Requesting individual balances for \(account.address)")
            throw Error.notImplemented // FIXME
        }
    }

    func updateTokenPrices(client: AnyBlockchainClient, tokens: [Token]) async throws {
        throw Error.notImplemented // FIXME
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
