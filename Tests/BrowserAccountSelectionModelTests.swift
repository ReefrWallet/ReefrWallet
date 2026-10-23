// Unit tests for BrowserAccountOrdering (hierarchy/sorting built from
// KeyStoreModel) and BrowserAccountSelectionModel (the @MainActor
// observable bridging that hierarchy to DappSession). Uses a real
// in-memory DatabaseService — AnvilTestSupport.swift's makeDatabaseService
// + makeLocalKeyStore/makeWatchOnlyKeyStore helpers, plus a local Trezor
// equivalent — so KeyStoreModel/AccountModel relationships are genuine
// SwiftData objects, not hand-rolled stand-ins.

import Foundation
import SwiftData
import Testing
import WalletKit
@testable import ReefrWallet

// MARK: - Fixtures

private func fetchKeyStoreModels(databaseService: DatabaseService) throws -> [KeyStoreModel] {
    let context = ModelContext(databaseService.modelContainer)
    return try context.fetch(FetchDescriptor<KeyStoreModel>())
}

private func makeTrezorKeyStore(
    databaseService: DatabaseService, name: String = "Trezor Test Key Store"
) async throws -> KeyStore {
    let keyStoreId = try await databaseService.insertKeyStore(
        KeyStore(deviceId: "test-device", kind: .trezor, name: name, transport: .usb, vendor: .trezor)
    )

    return KeyStore(
        deviceId: "test-device",
        id: keyStoreId,
        kind: .trezor,
        name: name,
        transport: .usb,
        vendor: .trezor
    )
}

private func insertAccount(
    databaseService: DatabaseService, keyStore: KeyStore, blockchain: Blockchain, address: String, name: String
) async throws {
    guard let keyStoreId = keyStore.id else {
        throw ReefrError.invalidData
    }

    let account = Account(
        address: address,
        blockchain: blockchain,
        derivationPath: try DerivationPath(string: "m/44'/60'/0'/0/0"),
        keyStoreId: keyStoreId,
        name: name
    )

    try await databaseService.insertAccount(account, keyStore: keyStore)
}

@MainActor
private final class BridgeNotificationCounter {
    private(set) var callCount = 0
    func increment() { callCount += 1 }
}

private func wait(_ task: Task<Void, Never>?) async {
    if let task {
        await task.value
    }
}

private struct SelectionModelFixture {
    let databaseService: DatabaseService
    let session: DappSession
    let trezorKeyStore: KeyStore
    let localKeyStore: KeyStore
    let watchOnlyKeyStore: KeyStore

    static func make() async throws -> SelectionModelFixture {
        let databaseService = try makeDatabaseService()
        return SelectionModelFixture(
            databaseService: databaseService,
            session: DappSession(origin: "https://dapp.example"),
            trezorKeyStore: try await makeTrezorKeyStore(databaseService: databaseService),
            localKeyStore: try await makeLocalKeyStore(databaseService: databaseService),
            watchOnlyKeyStore: try await makeWatchOnlyKeyStore(databaseService: databaseService)
        )
    }

    func groups() throws -> [BrowserAccountSelectionGroup] {
        BrowserAccountOrdering.groups(from: try fetchKeyStoreModels(databaseService: databaseService))
    }
}

// MARK: - BrowserAccountOrdering

@Suite(.timeLimit(.minutes(1)))
struct BrowserAccountOrderingTests {
    @Test
    func groupOrderMatchesSidebarHierarchyTrezorThenLocalThenWatchOnly() async throws {
        let fixture = try await SelectionModelFixture.make()
        try await insertAccount(
            databaseService: fixture.databaseService, keyStore: fixture.trezorKeyStore,
            blockchain: .evm(.ethereum(.sepolia)), address: "0x01", name: "Trezor ETH"
        )

        try await insertAccount(
            databaseService: fixture.databaseService, keyStore: fixture.localKeyStore,
            blockchain: .evm(.ethereum(.sepolia)), address: "0x02", name: "Local ETH"
        )

        try await insertAccount(
            databaseService: fixture.databaseService, keyStore: fixture.watchOnlyKeyStore,
            blockchain: .sui(.testnet), address: "sui-watch-address", name: "Watch Sui"
        )

        let groups = try fixture.groups()

        #expect(groups.map(\.name) == [fixture.trezorKeyStore.name, fixture.localKeyStore.name, "Watch-only Accounts"])
    }

    @Test
    func watchOnlyGroupIsUnsortedAndNeverExposesTheUnderlyingKeyStoreName() async throws {
        let fixture = try await SelectionModelFixture.make()

        // Inserted in an order that sorting-by-display-name would reverse.
        try await insertAccount(
            databaseService: fixture.databaseService, keyStore: fixture.watchOnlyKeyStore,
            blockchain: .sui(.testnet), address: "sui-watch-address", name: "Watch Sui"
        )

        try await insertAccount(
            databaseService: fixture.databaseService, keyStore: fixture.watchOnlyKeyStore,
            blockchain: .evm(.ethereum(.sepolia)), address: "0x03", name: "Watch ETH"
        )

        let groups = try fixture.groups()
        let watchOnlyGroup = try #require(groups.first { $0.name == "Watch-only Accounts" })

        #expect(watchOnlyGroup.id == fixture.watchOnlyKeyStore.id)
        #expect(watchOnlyGroup.accounts.map(\.name) == ["Watch Sui", "Watch ETH"]) // insertion order, not sorted
    }

    @Test
    func unsupportedChainAccountsAreExcludedAndEmptyKeyStoresAreNotSelectable() async throws {
        let fixture = try await SelectionModelFixture.make()
        // Bitcoin has no DappNamespace yet, so this key store has no
        // browser-supported accounts even though it has a real account.
        try await insertAccount(
            databaseService: fixture.databaseService, keyStore: fixture.trezorKeyStore,
            blockchain: .bitcoin(.regtest), address: "bitcoin-test-address", name: "Trezor BTC"
        )

        let groups = try fixture.groups()

        let bitcoinOnlyGroup = try #require(groups.first { $0.id == fixture.trezorKeyStore.id })
        #expect(bitcoinOnlyGroup.accounts.isEmpty)
        #expect(bitcoinOnlyGroup.isSelectable == false)

        let emptyLocalGroup = try #require(groups.first { $0.id == fixture.localKeyStore.id })
        #expect(emptyLocalGroup.accounts.isEmpty)
        #expect(emptyLocalGroup.isSelectable == false)
    }
}

// MARK: - BrowserAccountSelectionModel

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct BrowserAccountSelectionModelTests {
    @Test
    func defaultSelectionOnFirstReconcileIsSilent() async throws {
        let fixture = try await SelectionModelFixture.make()
        try await insertAccount(
            databaseService: fixture.databaseService, keyStore: fixture.trezorKeyStore,
            blockchain: .evm(.ethereum(.sepolia)), address: "0x01", name: "Trezor ETH"
        )

        let counter = BridgeNotificationCounter()
        let model = BrowserAccountSelectionModel(session: fixture.session) { counter.increment() }

        await wait(model.reconcile(groups: try fixture.groups()))

        #expect(model.selectedKeyStoreId == fixture.trezorKeyStore.id)
        #expect(await fixture.session.activeAccount?.name == "Trezor ETH")
        #expect(counter.callCount == 0)
    }

    @Test
    func reconcileIsANoOpWhenTheQueryRepublishesIdenticalData() async throws {
        let fixture = try await SelectionModelFixture.make()
        try await insertAccount(
            databaseService: fixture.databaseService, keyStore: fixture.localKeyStore,
            blockchain: .evm(.ethereum(.sepolia)), address: "0x01", name: "Local ETH"
        )

        let counter = BridgeNotificationCounter()
        let model = BrowserAccountSelectionModel(session: fixture.session) { counter.increment() }

        let groups = try fixture.groups()
        await wait(model.reconcile(groups: groups))

        let selectedKeyStoreId = model.selectedKeyStoreId
        let selectedAccountId = model.selectedAccountId

        let secondTask = model.reconcile(groups: groups)

        #expect(secondTask == nil)
        #expect(model.selectedKeyStoreId == selectedKeyStoreId)
        #expect(model.selectedAccountId == selectedAccountId)
        #expect(counter.callCount == 0)
    }

    @Test
    func reconcileFallsBackWhenTheSelectedAccountWasDeletedAndNotifiesTheBridge() async throws {
        let fixture = try await SelectionModelFixture.make()
        try await insertAccount(
            databaseService: fixture.databaseService, keyStore: fixture.trezorKeyStore,
            blockchain: .evm(.ethereum(.sepolia)), address: "0x01", name: "Trezor ETH"
        )

        try await insertAccount(
            databaseService: fixture.databaseService, keyStore: fixture.localKeyStore,
            blockchain: .evm(.ethereum(.sepolia)), address: "0x02", name: "Local ETH"
        )

        let counter = BridgeNotificationCounter()
        let model = BrowserAccountSelectionModel(session: fixture.session) { counter.increment() }

        // Trezor sorts first, so the default pick lands there.
        await wait(model.reconcile(groups: try fixture.groups()))
        let initialAccountId = try #require(model.selectedAccountId)
        #expect(counter.callCount == 0)

        try await fixture.databaseService.deleteAccount(id: initialAccountId)
        await wait(model.reconcile(groups: try fixture.groups()))

        #expect(model.selectedAccountId != initialAccountId)
        #expect(model.selectedKeyStoreId == fixture.localKeyStore.id) // the only account left
        #expect(counter.callCount == 1)
    }

    /// The fallback pick is the app's, not the user's, so a connected origin's
    /// grant must not follow it onto an account nobody approved.
    @Test
    func reconcileFallbackDoesNotInheritTheConnectedOriginsPermission() async throws {
        let fixture = try await SelectionModelFixture.make()
        try await insertAccount(
            databaseService: fixture.databaseService, keyStore: fixture.trezorKeyStore,
            blockchain: .evm(.ethereum(.sepolia)), address: "0x01", name: "Trezor ETH"
        )

        try await insertAccount(
            databaseService: fixture.databaseService, keyStore: fixture.localKeyStore,
            blockchain: .evm(.ethereum(.sepolia)), address: "0x02", name: "Local ETH"
        )

        let model = BrowserAccountSelectionModel(session: fixture.session) {}
        await wait(model.reconcile(groups: try fixture.groups()))

        let connectedAccountId = try #require(model.selectedAccountId)
        let connectedAccount = try #require(await fixture.session.activeAccount)
        #expect(await fixture.session.grantPermission(
            .ethereum, origin: fixture.session.origin, account: connectedAccount
        ))

        try await fixture.databaseService.deleteAccount(id: connectedAccountId)
        await wait(model.reconcile(groups: try fixture.groups()))

        #expect(model.selectedAccountId != connectedAccountId)
        #expect(await fixture.session.isPermitted(.ethereum) == false)
    }

    @Test
    func selectingAKeyStorePicksItsFirstAccount() async throws {
        let fixture = try await SelectionModelFixture.make()

        try await insertAccount(
            databaseService: fixture.databaseService, keyStore: fixture.trezorKeyStore,
            blockchain: .evm(.ethereum(.sepolia)), address: "0x01", name: "Trezor ETH"
        )

        try await insertAccount(
            databaseService: fixture.databaseService, keyStore: fixture.localKeyStore,
            blockchain: .evm(.ethereum(.sepolia)), address: "0x02", name: "Local ETH"
        )

        try await insertAccount(
            databaseService: fixture.databaseService, keyStore: fixture.localKeyStore,
            blockchain: .sui(.testnet), address: "sui-local-address", name: "Local Sui"
        )

        let counter = BridgeNotificationCounter()
        let model = BrowserAccountSelectionModel(session: fixture.session) { counter.increment() }

        let groups = try fixture.groups()
        await wait(model.reconcile(groups: groups)) // defaults to Trezor
        #expect(model.selectedKeyStoreId == fixture.trezorKeyStore.id)

        let localGroup = try #require(groups.first { $0.id == fixture.localKeyStore.id })
        await wait(model.selectKeyStore(localGroup))

        let expectedFirstAccount = try #require(localGroup.accounts.first)
        #expect(model.selectedKeyStoreId == fixture.localKeyStore.id)
        #expect(model.selectedAccountId == expectedFirstAccount.id)
        #expect(await fixture.session.activeAccount?.name == expectedFirstAccount.name)
        #expect(counter.callCount == 1)
    }

    @Test
    func selectingTheAlreadySelectedKeyStoreIsANoOp() async throws {
        let fixture = try await SelectionModelFixture.make()
        try await insertAccount(
            databaseService: fixture.databaseService, keyStore: fixture.localKeyStore,
            blockchain: .evm(.ethereum(.sepolia)), address: "0x01", name: "Local ETH"
        )

        let counter = BridgeNotificationCounter()
        let model = BrowserAccountSelectionModel(session: fixture.session) { counter.increment() }

        let groups = try fixture.groups()
        await wait(model.reconcile(groups: groups))
        #expect(counter.callCount == 0)

        let localGroup = try #require(groups.first { $0.id == fixture.localKeyStore.id })
        let task = model.selectKeyStore(localGroup)

        #expect(task == nil)
        #expect(counter.callCount == 0)
    }

    @Test
    func selectingAnAccountNotifiesTheBridge() async throws {
        let fixture = try await SelectionModelFixture.make()

        try await insertAccount(
            databaseService: fixture.databaseService, keyStore: fixture.localKeyStore,
            blockchain: .evm(.ethereum(.sepolia)), address: "0x01", name: "Local ETH 1"
        )

        try await insertAccount(
            databaseService: fixture.databaseService, keyStore: fixture.localKeyStore,
            blockchain: .sui(.testnet), address: "sui-local-address", name: "Local Sui"
        )

        let counter = BridgeNotificationCounter()
        let model = BrowserAccountSelectionModel(session: fixture.session) { counter.increment() }

        let groups = try fixture.groups()
        await wait(model.reconcile(groups: groups))
        #expect(counter.callCount == 0)

        let localGroup = try #require(groups.first { $0.id == fixture.localKeyStore.id })
        let otherAccount = try #require(localGroup.accounts.first { $0.id != model.selectedAccountId })
        await wait(model.select(otherAccount, in: localGroup))

        #expect(model.selectedAccountId == otherAccount.id)
        #expect(await fixture.session.activeAccount?.name == otherAccount.name)
        #expect(counter.callCount == 1)
    }

    @Test
    func selectingTheAlreadySelectedAccountIsANoOp() async throws {
        let fixture = try await SelectionModelFixture.make()
        try await insertAccount(
            databaseService: fixture.databaseService, keyStore: fixture.localKeyStore,
            blockchain: .evm(.ethereum(.sepolia)), address: "0x01", name: "Local ETH"
        )

        let counter = BridgeNotificationCounter()
        let model = BrowserAccountSelectionModel(session: fixture.session) { counter.increment() }

        let groups = try fixture.groups()
        await wait(model.reconcile(groups: groups))
        let selectedGroup = try #require(groups.first { $0.isSelectable })
        let selectedAccount = try #require(selectedGroup.accounts.first)

        #expect(model.select(selectedAccount, in: selectedGroup) == nil)
        #expect(counter.callCount == 0)
    }

    @Test
    func syncFromProviderDrivenChangeUpdatesDisplayedIdsWithoutTouchingTheSession() async throws {
        let fixture = try await SelectionModelFixture.make()
        try await insertAccount(
            databaseService: fixture.databaseService, keyStore: fixture.localKeyStore,
            blockchain: .evm(.ethereum(.sepolia)), address: "0x01", name: "Local ETH 1"
        )

        try await insertAccount(
            databaseService: fixture.databaseService, keyStore: fixture.localKeyStore,
            blockchain: .evm(.custom(999)), address: "0x02", name: "Local ETH 2"
        )

        let counter = BridgeNotificationCounter()
        let model = BrowserAccountSelectionModel(session: fixture.session) { counter.increment() }

        let groups = try fixture.groups()
        await wait(model.reconcile(groups: groups))
        let activeAccountBeforeSync = await fixture.session.activeAccount

        let localGroup = try #require(groups.first { $0.id == fixture.localKeyStore.id })
        let otherAccountModel = try #require(localGroup.accounts.first { $0.id != model.selectedAccountId })
        let otherAccount = try Account(model: otherAccountModel)

        model.syncFromProviderDrivenChange(otherAccount, groups: groups)

        #expect(model.selectedAccountId == otherAccountModel.id)
        #expect(model.selectedKeyStoreId == fixture.localKeyStore.id)
        #expect(await fixture.session.activeAccount == activeAccountBeforeSync) // untouched by sync
        #expect(counter.callCount == 0) // sync never notifies the bridge
    }
}
