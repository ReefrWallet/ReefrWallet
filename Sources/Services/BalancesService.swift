import BigInt
import Foundation
import SwiftData
import WalletKit

final class BalancesService {
    private lazy var clientProvider = DI.injectOrFail(BlockchainClientProvider.self)
    private lazy var databaseService = DI.injectOrFail(DatabaseService.self)

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

    @MainActor // swiftlint:disable:next function_body_length
    func updateBalances(_ account: Account) async throws {
        let client = try clientProvider.getClient(blockchain: account.blockchain)
        let tokens = try await databaseService.fetchTokens(account: account)

        var balances: [Balance] = []

        if client.isSupported(.allBalances) {
            for (tokenAddress, amount) in try await client.getAllBalances(account.address) {
                if var token = tokens.first(where: { $0.address == tokenAddress }) {
                    if let price = try? await client.getTokenPrice(tokenAddress) {
                        token.usdPrice = price
                    }

                    let decimalAmount = Decimal(
                        sign: .plus,
                        exponent: -Int(token.decimalsCount),
                        significand: Decimal(amount)
                    )

                    balances.append(Balance(
                        account: account,
                        amount: amount,
                        token: token,
                        usdValue: token.usdPrice.map { $0 * decimalAmount }
                    ))
                } else {
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

                    let decimalAmount = Decimal(
                        sign: .plus,
                        exponent: -Int(token.decimalsCount),
                        significand: Decimal(amount)
                    )

                    balances.append(Balance(
                        account: account,
                        amount: amount,
                        token: token,
                        usdValue: token.usdPrice.map { $0 * decimalAmount }
                    ))
                }
            }
        } else {
            for token in tokens {
                let amount: BigUInt
                if token.isNativeToken {
                    amount = try await client.getNativeBalance(account.address)
                } else if let address = token.address {
                    amount = try await client.getBalance(account.address, token: address)
                } else {
                    throw Error.invalidData
                }

                var token = token
                if let price = try? await client.getTokenPrice(token.address) {
                    token.usdPrice = price
                }

                let decimalAmount = Decimal(
                    sign: .plus,
                    exponent: -Int(token.decimalsCount),
                    significand: Decimal(amount)
                )

                balances.append(Balance(
                    account: account,
                    amount: amount,
                    token: token,
                    usdValue: token.usdPrice.map { $0 * decimalAmount }
                ))
            }
        }

        try await databaseService.updateBalances(account: account, updates: balances)
    }
}
