import BigInt
import Foundation
import SwiftData
import SwiftUI
import WalletKit

// MARK: - BalancesService

final class BalancesService {
    private lazy var clientProvider = DI.injectOrFail(BlockchainClientProvider.self)
    private let databaseService: DatabaseService

    init(databaseService: DatabaseService? = nil) {
        self.databaseService = databaseService ?? DI.injectOrFail(DatabaseService.self)
    }

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
            let allTokens = try (storedTokens + readConfiguredTokens(blockchain: account.blockchain)
                .filter { token in
                    !storedTokens.contains { $0.address == token.address }
                }
            ).filter { !$0.isNativeToken }

            let nativeBalance = try await fetchNativeBalance(
                client: client,
                account: account,
                storedTokens: storedTokens
            )

            try await databaseService.updateBalances(account: account, updates: [nativeBalance])
            try await updateTokenBalances(client: client, account: account, tokens: allTokens)
        }
    }

    func updateTokenPrices(_ account: Account) async throws {
        let client = try clientProvider.getClient(
            blockchain: account.blockchain,
            rpcURL: account.rpcURLOverride
        )

        let tokens = try await databaseService.fetchTokens(blockchain: account.blockchain)

        let updatedTokens = await withTaskGroup(of: Token?.self) { group in
            for token in tokens {
                group.addTask {
                    do {
                        let usdPrice = try await client.getTokenPrice(token.address)
                        var updatedToken = token
                        updatedToken.usdPrice = usdPrice
                        return updatedToken
                    } catch {
                        printError(error)
                        return nil
                    }
                }
            }

            var results: [Token] = []
            for await updatedToken in group {
                if let updatedToken {
                    results.append(updatedToken)
                }
            }
            return results
        }

        try await databaseService.updateTokenPrices(updatedTokens)
    }

    func usdValue(accountId: PersistentIdentifier) async throws -> Decimal {
        try await databaseService.usdValue(accountId: accountId)
    }

    func usdValue(keyStoreId: PersistentIdentifier) async throws -> Decimal {
        try await databaseService.usdValue(keyStoreId: keyStoreId)
    }
}

// MARK: - Private

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

    func updateBalance(account: Account, client: AnyBlockchainClient, token: Token) async throws {
        guard let tokenAddress = token.address else {
            throw Error.invalidData
        }

        let amount = try await client.getBalance(account.address, token: tokenAddress)

        if var storedBalance: Balance = try await databaseService.fetchBalance(
            account: account,
            token: token
        ) {
            storedBalance.amount = amount
            try await databaseService.saveBalance(storedBalance)
        } else if let storedToken = try await databaseService.fetchToken(
            tokenAddress: tokenAddress,
            blockchain: account.blockchain
        ) {
            let balance = try await makeBalance(account: account, amount: amount, token: storedToken)
            try await databaseService.saveBalance(balance)
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
                    // Update stored balance for token
                    storedBalance.amount = amount
                    try await databaseService.saveBalance(storedBalance)
                } else if amount > 0 {
                    // Create new balance for token
                    let balance = Balance(
                        account: account,
                        amount: amount,
                        token: storedToken,
                        usdValue: nil
                    )
                    try await databaseService.saveBalance(balance)
                }
            } else if amount > 0 {
                // Create new token and balance
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

    func updateIndividualBalances(
        client: AnyBlockchainClient,
        account: Account,
        tokens: [Token]
    ) async throws {
        printDebug("Requesting individual balances for \(account.address)")
        var remainingTokens = tokens

        await withTaskGroup(of: Void.self) { group in
            while !remainingTokens.isEmpty {
                guard let token = Array(remainingTokens.prefix(1)).first else {
                    fatalError()
                }

                remainingTokens.removeFirst(tokens.count)

                group.addTask {
                    do {
                        try await self.updateBalance(account: account, client: client, token: token)
                    } catch {
                        printError(error)
                    }
                }
            }
        }
    }

    func updateTokenBalances(
        client: AnyBlockchainClient,
        account: Account,
        tokens: [Token]
    ) async throws {
        guard client.isSupported(.multipleBalances) else {
            try await updateIndividualBalances(client: client, account: account, tokens: tokens)
            return
        }

        printDebug("Requesting bulk balances for \(account.address)")
        var remainingTokens = tokens

        await withTaskGroup(of: Void.self) { group in
            while !remainingTokens.isEmpty {
                let batch = Array(remainingTokens.prefix(20))
                remainingTokens.removeFirst(batch.count)

                group.addTask {
                    do {
                        try await self.updateBalances(account: account, client: client, tokens: batch)
                    } catch {
                        printError(error)
                    }
                }
            }

            await group.waitForAll()
        }
    }
}

// MARK: - Bundled configuration

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
