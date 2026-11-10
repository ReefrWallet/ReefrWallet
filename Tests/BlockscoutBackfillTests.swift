// The Blockscout backfill pages ERC-20 transfers alongside transactions, so a token
// received before the first sync (a transaction the account didn't send) is discovered.

import Foundation
@testable import ReefrWallet
import Testing
import WalletKit

/// Serves canned Blockscout pages keyed by path and query, per stub host.
private final class BlockscoutStubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Stub {
        let host: String
        let configuration: URLSessionConfiguration

        func requests(path: String) -> [URLRequest] {
            BlockscoutStubURLProtocol.requests(host: host).filter { $0.url?.path == "/api/v2/addresses/\(path)" }
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [String: [String: String]] = [:]
    nonisolated(unsafe) private static var captured: [String: [URLRequest]] = [:]

    /// `routes` maps `"<address>/<list>"` or `"<address>/<list>?<sorted query>"` to a JSON body.
    static func make(routes: [String: String]) -> Stub {
        let host = "blockscout-\(UUID().uuidString.lowercased()).test"
        lock.withLock { self.routes[host] = routes }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BlockscoutStubURLProtocol.self]
        return Stub(host: host, configuration: configuration)
    }

    static func requests(host: String) -> [URLRequest] {
        lock.withLock { captured[host] ?? [] }
    }

    override static func canInit(with request: URLRequest) -> Bool { true }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let host = url.host ?? ""
        let list = url.path.replacingOccurrences(of: "/api/v2/addresses/", with: "")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .filter { $0.name != "type" }
            .map { "\($0.name)=\($0.value ?? "")" }
            .sorted()
            .joined(separator: "&")

        let key = query.flatMap { $0.isEmpty ? nil : "\(list)?\($0)" } ?? list
        let body = Self.lock.withLock { () -> String? in
            Self.captured[host, default: []].append(request)
            return Self.routes[host]?[key]
        }

        let status = body == nil ? 404 : 200
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((body ?? "not found").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

struct BlockscoutBackfillTests {
    private static let owner = "0x261B90cA1f43BaE342e6a55192A514E1eDa1CE0d"
    private static let usdc = "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238"
    private static let sepolia = Blockchain.evm(.ethereum(.sepolia))

    private static func transaction(hash: String, block: Int) -> String {
        """
        {"block_number":\(block),"fee":{"value":"21"},"from":{"hash":"\(owner)"},"hash":"\(hash)","method":null,
         "status":"ok","timestamp":"2026-01-01T00:00:00.000000Z","to":{"hash":"0xbbbb"},"value":"5"}
        """
    }

    private static func transfer(hash: String, block: Int, value: String) -> String {
        """
        {"block_number":\(block),"from":{"hash":"0xaaaa"},"log_index":3,"timestamp":"2026-01-01T00:00:00.000000Z",
         "to":{"hash":"\(owner)"},"token":{"address_hash":"\(usdc)","decimals":"6","name":"USDC","symbol":"USDC"},
         "total":{"value":"\(value)"},"transaction_hash":"\(hash)"}
        """
    }

    private static func list(_ items: [String], next: String? = nil) -> String {
        "{\"items\":[\(items.joined(separator: ","))],\"next_page_params\":\(next ?? "null")}"
    }

    private func makeSource(_ stub: BlockscoutStubURLProtocol.Stub) -> BlockscoutTransactionHistorySource {
        BlockscoutTransactionHistorySource(
            apiBaseURLs: [11_155_111: URL(string: "https://\(stub.host)/api/v2")!],
            sessionConfiguration: stub.configuration
        )
    }

    private func makeAccount() async throws -> ReefrWallet.Account {
        let databaseService = try makeDatabaseService()
        let keyStore = try await makeWatchOnlyKeyStore(databaseService: databaseService, name: "Blockscout Backfill")
        var account = ReefrWallet.Account(
            address: Self.owner,
            blockchain: Self.sepolia,
            derivationPath: nil,
            keyStoreId: try #require(keyStore.id),
            name: "Blockscout"
        )

        account.id = try await databaseService.insertAccount(account, keyStore: keyStore)
        return account
    }

    private func backfill(
        _ source: BlockscoutTransactionHistorySource,
        account: ReefrWallet.Account,
        cursor: Data? = nil
    ) async throws -> BlockchainTransactionPage {
        try await source.transactionHistory(
            account: account,
            request: BlockchainTransactionHistoryRequest(
                cursor: cursor,
                direction: .descending,
                lowerBound: 0,
                upperBound: nil
            )
        )
    }

    @Test func aTokenReceivedInATransactionTheAccountDidNotSendIsDiscovered() async throws {
        let stub = BlockscoutStubURLProtocol.make(routes: [
            "\(Self.owner)/transactions": Self.list([Self.transaction(hash: "0xsent", block: 200)]),
            "\(Self.owner)/token-transfers": Self.list([Self.transfer(hash: "0xreceived", block: 100, value: "20000000")])
        ])

        let page = try await backfill(makeSource(stub), account: try await makeAccount())

        let received = try #require(page.transactions.first { $0.identifier == "0xreceived" })
        let effect = try #require(received.effects.first { $0.kind == .tokenTransfer })
        #expect(effect.assetIdentifier == Self.usdc)
        #expect(effect.amount == "20000000")
        #expect(page.transactions.contains { $0.identifier == "0xsent" })
        #expect(page.reachedBoundary)
        #expect(page.nextCursor == nil)
        #expect(page.head == 200)
    }

    @Test func bothListsArePagedUntilEachIsExhausted() async throws {
        let next = #"{"block_number":150,"index":0,"items_count":50}"#
        let stub = BlockscoutStubURLProtocol.make(routes: [
            "\(Self.owner)/transactions": Self.list([Self.transaction(hash: "0xnew", block: 200)], next: next),
            "\(Self.owner)/transactions?block_number=150&index=0&items_count=50":
                Self.list([Self.transaction(hash: "0xold", block: 120)]),
            "\(Self.owner)/token-transfers": Self.list([Self.transfer(hash: "0xtoken", block: 190, value: "1")])
        ])

        let source = makeSource(stub)
        let account = try await makeAccount()

        let first = try await backfill(source, account: account)
        #expect(!first.reachedBoundary)
        let cursor = try #require(first.nextCursor)

        let second = try await backfill(source, account: account, cursor: cursor)
        #expect(second.reachedBoundary)
        #expect(second.transactions.map(\.identifier) == ["0xold"])

        // The finished token list isn't requested again.
        #expect(stub.requests(path: "\(Self.owner)/token-transfers").count == 1)
        #expect(stub.requests(path: "\(Self.owner)/transactions").count == 2)
    }

    @Test func aCursorSavedByAnOlderVersionStillResumesTheTransactionList() async throws {
        let legacy = #"{"block_number":150,"index":0,"items_count":50}"#
        let stub = BlockscoutStubURLProtocol.make(routes: [
            "\(Self.owner)/transactions?block_number=150&index=0&items_count=50":
                Self.list([Self.transaction(hash: "0xold", block: 120)]),
            "\(Self.owner)/token-transfers": Self.list([Self.transfer(hash: "0xtoken", block: 190, value: "1")])
        ])

        let page = try await backfill(
            makeSource(stub),
            account: try await makeAccount(),
            cursor: Data(legacy.utf8)
        )

        // Transactions resume where they stopped; token transfers start from the newest.
        #expect(Set(page.transactions.map(\.identifier)) == ["0xold", "0xtoken"])
        #expect(page.reachedBoundary)
    }

    @Test func aPendingTransactionDoesNotFailThePage() async throws {
        let pending = """
        {"block_number":null,"fee":{"value":"21"},"from":{"hash":"\(Self.owner)"},"hash":"0xpending","method":null,
         "status":null,"timestamp":null,"to":{"hash":"0xbbbb"},"value":"5"}
        """

        let stub = BlockscoutStubURLProtocol.make(routes: [
            "\(Self.owner)/transactions": Self.list([pending, Self.transaction(hash: "0xmined", block: 200)]),
            "\(Self.owner)/token-transfers": Self.list([])
        ])

        let page = try await backfill(makeSource(stub), account: try await makeAccount())

        #expect(page.transactions.map(\.identifier) == ["0xmined"])
        #expect(page.reachedBoundary)
    }
}
