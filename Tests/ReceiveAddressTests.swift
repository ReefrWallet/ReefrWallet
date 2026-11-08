import BigInt
import Foundation
import SwiftData
import Testing
import WalletKit
@testable import ReefrWallet

/// Cardano receive addresses: the sheet's states, storage, and the refresh that fills them.
@Suite(.timeLimit(.minutes(1)))
struct ReceiveAddressTests {
    private static let assetUnit = String(repeating: "ab", count: 28) + "4e49474854"

    // MARK: Sheet state

    private func rows(_ indices: [UInt32], used: Set<UInt32> = []) -> [ReceiveAddress] {
        indices.map { ReceiveAddress(address: "addr\($0)", index: $0, isUsed: used.contains($0), lovelace: nil) }
    }

    @Test func theSheetSuggestsOnePastTheNewestListedAddress() {
        let draft = ReceiveAddressDraft(rows: rows([0, 3]))

        #expect(draft.index == 4)
        #expect(draft.note == .next(index: 4, newest: 3))
        #expect(draft.isAddEnabled)
    }

    @Test func theSheetFallsBackToTheLowestFreeIndexAtTheLimit() {
        let draft = ReceiveAddressDraft(rows: rows([0, 999]))

        #expect(draft.index == 1)
        #expect(draft.note == .lowestFree(index: 1))
    }

    @Test func theSheetRefusesWhenEveryIndexIsListed() {
        let draft = ReceiveAddressDraft(rows: rows(Array(0..<1_000)))

        #expect(draft.index == nil)
        #expect(draft.note == .allListed)
        #expect(!draft.isAddEnabled)
    }

    @Test(arguments: ["", "abc", "-1", "1000", "3"])
    func aCustomIndexMustBeUnlistedAndBelowTheLimit(text: String) {
        let draft = ReceiveAddressDraft(rows: rows([0, 3]), isCustom: true, text: text)

        #expect(draft.index == nil)
        #expect(draft.note == .invalidIndex)
        #expect(!draft.isAddEnabled)
    }

    @Test func aValidCustomIndexIsDerivedAsTyped() {
        let draft = ReceiveAddressDraft(rows: rows([0]), isCustom: true, text: " 999 ")

        #expect(draft.index == 999)
        #expect(draft.note == .custom(index: 999))
    }

    @Test func theGapWarningCountsFromTheLastOnChainUsedIndexNotTheLastListedOne() {
        let listed = rows([0, 3, 40], used: [0, 3])

        #expect(!ReceiveAddressDraft(rows: listed, isCustom: true, text: "23").isPastGap)
        #expect(ReceiveAddressDraft(rows: listed, isCustom: true, text: "24").isPastGap)
        // Nothing used yet: the window is 0...19.
        #expect(!ReceiveAddressDraft(rows: rows([0]), isCustom: true, text: "19").isPastGap)
        #expect(ReceiveAddressDraft(rows: rows([0]), isCustom: true, text: "20").isPastGap)
        // A single high address doesn't move the window.
        #expect(!ReceiveAddressDraft(rows: rows([0, 999]), isCustom: false).isPastGap)
    }

    // MARK: Storage

    @Test func rowsAreScopedToTheirAccountAndInsertIsIdempotent() async throws {
        let (databaseService, accounts) = try await makeTwoAccounts()
        let (first, second) = (accounts[0], accounts[1])
        let firstId = try #require(first.id)
        let secondId = try #require(second.id)

        let service = ReceiveAddressService(databaseService: databaseService)
        try await service.add(index: 4, to: first)
        try await service.add(index: 4, to: first)
        try await service.add(index: 4, to: second)

        let firstRows = try await databaseService.fetchReceiveAddresses(accountId: firstId)
        let secondRows = try await databaseService.fetchReceiveAddresses(accountId: secondId)
        let firstAddress = try CardanoAccountDescriptor(string: first.address).address(role: 0, index: 4).string
        let secondAddress = try CardanoAccountDescriptor(string: second.address).address(role: 0, index: 4).string

        #expect(firstRows.map(\.address) == [firstAddress])
        #expect(secondRows.map(\.address) == [secondAddress])
        #expect(firstAddress != secondAddress)
        #expect(firstRows.first?.isUsed == nil)
    }

    @Test func anOfflineAddLeavesDiscoveryPending() async throws {
        let (databaseService, accounts) = try await makeTwoAccounts()
        let account = accounts[0]
        let accountId = try #require(account.id)

        try await ReceiveAddressService(databaseService: databaseService).ensureBaseRow(for: account)
        try await ReceiveAddressService(databaseService: databaseService).add(index: 7, to: account)

        #expect(try await databaseService.fetchReceiveAddresses(accountId: accountId).map(\.index) == [0, 7])
        #expect(try await databaseService.receiveAddressesObservedAt(accountId: accountId) == nil)
    }

    @Test func deletingTheAccountDeletesItsRows() async throws {
        let (databaseService, accounts) = try await makeTwoAccounts()
        let (account, other) = (accounts[0], accounts[1])
        let accountId = try #require(account.id)
        let otherId = try #require(other.id)

        try await ReceiveAddressService(databaseService: databaseService).ensureBaseRow(for: account)
        try await ReceiveAddressService(databaseService: databaseService).ensureBaseRow(for: other)
        try await databaseService.deleteAccount(id: accountId)

        #expect(try await databaseService.fetchReceiveAddresses(accountId: accountId).isEmpty)
        #expect(try await databaseService.fetchReceiveAddresses(accountId: otherId).count == 1)
    }

    @Test func aRefreshThatFinishesAfterTheAccountWasDeletedFailsWithoutCrashing() async throws {
        let (databaseService, accounts) = try await makeTwoAccounts()
        let account = accounts[0]
        let accountId = try #require(account.id)
        let owner = try CardanoAccountDescriptor(string: account.address)
        let rows = try await client(makeStub(owner, addresses: [], utxos: []))
            .receiveAddresses(owner, including: [], snapshot: .empty)

        try await databaseService.deleteAccount(id: accountId)

        await #expect(throws: ReefrError.self) {
            try await databaseService.applyReceiveAddresses(accountId: accountId, rows: rows, observedAt: .now)
        }

        await #expect(throws: ReefrError.self) {
            try await databaseService.insertReceiveAddressIfMissing(accountId: accountId, address: "addr", index: 1)
        }

        #expect(try await databaseService.receiveAddressesObservedAt(accountId: accountId) == nil)
    }

    // MARK: Refresh

    @Test func aRefreshStoresAmountsAndKeepsAddedRows() async throws {
        let (databaseService, accounts) = try await makeTwoAccounts()
        let account = accounts[0]
        let accountId = try #require(account.id)
        let owner = try CardanoAccountDescriptor(string: account.address)
        let funded = try owner.address(role: 0, index: 2).string
        let service = BalancesService(databaseService: databaseService)

        try await ReceiveAddressService(databaseService: databaseService).add(index: 9, to: account)

        let stub = makeStub(owner, addresses: [funded], utxos: [StubUTxO(address: funded, lovelace: "7000000")])
        try await service.updateCardanoBalances(account, client: client(stub))

        let stored = try await databaseService.fetchReceiveAddresses(accountId: accountId)
        let native = try await databaseService.fetchBalances(accountId: accountId).first { $0.token.isNativeToken }

        #expect(stored.map(\.index) == [0, 2, 9])
        #expect(stored.map(\.isUsed) == [false, true, false])
        #expect(stored.map(\.lovelace) == [0, 7_000_000, 0])
        #expect(native?.amount == 7_000_000)
        #expect(try await databaseService.receiveAddressesObservedAt(accountId: accountId) != nil)
    }

    @Test func spendingEverythingZeroesTheTotalsTheTokensAndTheAddressRow() async throws {
        let (databaseService, accounts) = try await makeTwoAccounts()
        let account = accounts[0]
        let accountId = try #require(account.id)
        let owner = try CardanoAccountDescriptor(string: account.address)
        let address = owner.receiveAddress.string
        let service = BalancesService(databaseService: databaseService)

        _ = try await databaseService.insertToken(assetToken(), blockchain: account.blockchain)

        // The asset's metadata request fails (404): the stored token is still updated.
        let token = StubAsset(unit: Self.assetUnit, quantity: "42")
        let funded = makeStub(
            owner, addresses: [address], utxos: [StubUTxO(address: address, lovelace: "5000000", asset: token)]
        )

        try await service.updateCardanoBalances(account, client: client(funded))

        var balances = try await databaseService.fetchBalances(accountId: accountId)
        #expect(balances.first { $0.token.isNativeToken }?.amount == 5_000_000)
        #expect(balances.first { !$0.token.isNativeToken }?.amount == 42)

        let empty = makeStub(owner, addresses: [address], utxos: [])
        try await service.updateCardanoBalances(account, client: client(empty))

        balances = try await databaseService.fetchBalances(accountId: accountId)
        let rows = try await databaseService.fetchReceiveAddresses(accountId: accountId)

        #expect(balances.first { $0.token.isNativeToken }?.amount == 0)
        #expect(balances.first { !$0.token.isNativeToken }?.amount == 0)
        #expect(rows.first?.lovelace == 0)
    }

    @Test func aFailedAddressReadStillSavesBalancesAndLeavesRowsAlone() async throws {
        let (databaseService, accounts) = try await makeTwoAccounts()
        let account = accounts[0]
        let accountId = try #require(account.id)
        let owner = try CardanoAccountDescriptor(string: account.address)
        let address = owner.receiveAddress.string
        let service = BalancesService(databaseService: databaseService)

        let stub = makeStub(
            owner,
            addresses: [address],
            utxos: [StubUTxO(address: address, lovelace: "3000000")],
            status: ["/api/v0/accounts/\(owner.stakeAddress)/addresses": 500]
        )

        try await service.updateCardanoBalances(account, client: client(stub))

        let native = try await databaseService.fetchBalances(accountId: accountId).first { $0.token.isNativeToken }

        #expect(native?.amount == 3_000_000)
        #expect(try await databaseService.fetchReceiveAddresses(accountId: accountId).isEmpty)
        #expect(try await databaseService.receiveAddressesObservedAt(accountId: accountId) == nil)
    }

    @Test func refreshesOfOneAccountNeverOverlap() async throws {
        let (databaseService, accounts) = try await makeTwoAccounts()
        let account = accounts[0]
        let owner = try CardanoAccountDescriptor(string: account.address)
        let service = BalancesService(databaseService: databaseService)
        let stub = makeStub(owner, addresses: [], utxos: [], delay: 0.15)
        let cardano = client(stub)

        async let first: Void = service.updateCardanoBalances(account, client: cardano)
        async let second: Void = service.updateCardanoBalances(account, client: cardano)
        _ = try await (first, second)

        let path = "/api/v0/accounts/\(owner.stakeAddress)/utxos"

        #expect(stub.requestCount(path: path) == 2)
        #expect(stub.maxConcurrentRequests(path: path) == 1)
    }
}

// MARK: - Support

private extension ReceiveAddressTests {
    func assetToken() -> Token {
        Token(
            address: Self.assetUnit,
            blockchain: .cardano(.preprod),
            decimalsCount: 0,
            imageURL: nil,
            isHidden: false,
            isIncludedInBalance: true,
            isNativeToken: false,
            name: "Night",
            symbol: "NIGHT",
            usdPrice: nil
        )
    }

    func client(_ stub: CardanoStubURLProtocol.Stub) -> CardanoClient {
        CardanoClient(endpoint: stub.endpoint, projectId: "project-id", session: stub.session)
    }

    struct StubAsset {
        let unit: String
        let quantity: String
    }

    struct StubUTxO {
        let address: String
        let lovelace: String
        var asset: StubAsset?
    }

    func makeStub(
        _ owner: CardanoAccountDescriptor,
        addresses: [String],
        utxos: [StubUTxO],
        status: [String: Int] = [:],
        delay: TimeInterval = 0
    ) -> CardanoStubURLProtocol.Stub {
        let listed = "[" + addresses.map { #"{"address":"\#($0)"}"# }.joined(separator: ",") + "]"
        let entries = utxos.enumerated().map { offset, utxo in
            var amounts = #"{"unit":"lovelace","quantity":"\#(utxo.lovelace)"}"#

            if let asset = utxo.asset {
                amounts += #",{"unit":"\#(asset.unit)","quantity":"\#(asset.quantity)"}"#
            }

            return """
            {"address":"\(utxo.address)","amount":[\(amounts)],"output_index":\(offset),
             "tx_hash":"\(String(repeating: "0\(offset % 10)", count: 32))"}
            """
        }

        return CardanoStubURLProtocol.make(
            routes: [
                "/api/v0/accounts/\(owner.stakeAddress)/addresses": listed,
                "/api/v0/accounts/\(owner.stakeAddress)/utxos": "[" + entries.joined(separator: ",") + "]"
            ],
            status: status,
            delay: delay
        )
    }

    /// Two watch-only Cardano accounts with different keys, so the same index derives different addresses.
    func makeTwoAccounts() async throws -> (database: DatabaseService, accounts: [ReefrWallet.Account]) {
        let databaseService = try makeDatabaseService()
        let keyStore = try await makeWatchOnlyKeyStore(databaseService: databaseService)
        let keyStoreId = try #require(keyStore.id)
        var accounts: [ReefrWallet.Account] = []

        for seed in [UInt8(1), 2] {
            let descriptor = try CardanoAccountDescriptor(
                entropy: Data(repeating: seed, count: 16),
                network: .preprod,
                path: .cardanoAccount(accountIndex: 0)
            )

            var account = Account(
                address: descriptor.string,
                blockchain: .cardano(.preprod),
                derivationPath: nil,
                keyStoreId: keyStoreId,
                name: "Cardano #\(seed)"
            )

            account.id = try await databaseService.insertAccount(account, keyStore: keyStore)
            accounts.append(account)
        }

        return (databaseService, accounts)
    }
}
