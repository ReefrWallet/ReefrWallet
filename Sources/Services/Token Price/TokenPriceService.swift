import SwiftData
import WalletKit

/// Fetches and persists token USD prices through an ordered source registry.
final class TokenPriceService: @unchecked Sendable {
    private let databaseService: DatabaseService?
    private let sources: [any PriceSource]

    init(
        databaseService: DatabaseService? = nil,
        sources: [any PriceSource]? = nil
    ) {
        if let sources {
            self.databaseService = databaseService
            self.sources = sources
        } else {
            self.databaseService = databaseService ?? DI.injectOrFail(DatabaseService.self)

            let clientProvider = DI.injectOrFail(BlockchainClientProvider.self)
            self.sources = [
                ChainlinkPriceSource(clientProvider: clientProvider),
                UniswapV3PriceSource(clientProvider: clientProvider),
                CetusPriceSource(clientProvider: clientProvider)
            ]
        }
    }

    func usdPrice(_ token: Token, rpcURL: URL) async throws -> Decimal {
        var mostRecentError: (any Swift.Error)?

        for source in sources {
            do {
                if let price = try await source.usdPrice(token, rpcURL: rpcURL) {
                    return price
                }
            } catch {
                mostRecentError = error
            }
        }

        if let mostRecentError {
            throw mostRecentError
        }

        throw WalletKitError.unsupportedFeature
    }

    func updateTokenPrices(_ account: Account) async throws {
        guard let databaseService else {
            throw WalletKitError.unsupportedFeature
        }

        let tokens = try await databaseService.fetchTokens(account: account)

        let updatedTokens = await withTaskGroup(of: Token?.self) { group in
            for token in tokens {
                group.addTask { [self] in
                    do {
                        let usdPrice = try await usdPrice(
                            token,
                            rpcURL: account.rpcURLOverride ?? account.blockchain.rpcURL
                        )

                        var updatedToken = token
                        updatedToken.usdPrice = usdPrice
                        return updatedToken
                    } catch {
                        printError("\(account.name): \(error)")
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
}
