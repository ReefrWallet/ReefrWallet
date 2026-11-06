import Foundation
import Testing
import WalletKit
@testable import ReefrWallet

/// A database with one account on Ethereum mainnet and helpers to store tokens on it.
struct TokenSourceFixture {
    static let blockchain = Blockchain.evm(.ethereum(.mainnet))

    let account: ReefrWallet.Account
    let databaseService: DatabaseService

    init() async throws {
        databaseService = try makeDatabaseService()

        let keyStore = try await databaseService.watchOnlyKeyStore()

        var account = ReefrWallet.Account(
            address: "0x" + String(repeating: "11", count: 20),
            blockchain: Self.blockchain,
            derivationPath: nil,
            keyStoreId: try #require(keyStore.id),
            name: "Source Test"
        )

        account.id = try await databaseService.insertAccount(account, keyStore: keyStore)
        self.account = account
    }

    /// Stores a token the account holds.
    @discardableResult
    func insertToken(
        _ suffix: String,
        isWhitelisted: Bool = false,
        symbol: String = "TOK",
        usdPrice: Decimal? = nil
    ) async throws -> Token {
        let token = Self.token(suffix, isWhitelisted: isWhitelisted, symbol: symbol, usdPrice: usdPrice)
        _ = try await databaseService.insertToken(token, blockchain: Self.blockchain)
        try await databaseService.saveBalance(Balance(account: account, amount: 25, token: token, usdValue: nil))
        return token
    }

    func storedToken(_ token: Token) async throws -> Token {
        let address = try #require(token.address)
        return try #require(try await databaseService.fetchToken(tokenAddress: address, blockchain: Self.blockchain))
    }

    func statuses(_ kind: TokenSourceKind, of token: Token) async throws -> [TokenSourceStatus] {
        try await databaseService.fetchTokenSourceStatuses(kind: kind, for: [token])[0]
    }

    static func address(_ suffix: String) -> String {
        "0x" + String(repeating: "0", count: 40 - suffix.count) + suffix
    }

    static func token(
        _ suffix: String,
        isWhitelisted: Bool = false,
        symbol: String = "TOK",
        usdPrice: Decimal? = nil
    ) -> Token {
        Token(
            address: address(suffix),
            blockchain: blockchain,
            coinGeckoId: nil,
            decimalsCount: 0,
            imageURL: nil,
            isHidden: false,
            isIncludedInBalance: true,
            isNativeToken: false,
            isWhitelisted: isWhitelisted,
            name: symbol,
            symbol: symbol,
            usdPrice: usdPrice
        )
    }
}

/// Counts calls from concurrent code.
final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.withLock { value }
    }

    var isEmpty: Bool {
        lock.withLock { value == 0 }
    }

    func increment() {
        lock.withLock { value += 1 }
    }
}

/// A mutable value shared with `@Sendable` closures.
final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
