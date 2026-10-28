// Tests for choosing and remembering the account a dapp connects with: the
// bridge's pre-connect step (remembered account, chooser, quiet checks), the
// chains a dapp asked for, and the details pane's grant editing.

import Foundation
import SwiftData
import Testing
import WalletKit
@testable import ReefrWallet

/// Registered under `cardano`; only `enable` is a connect request.
private actor ConnectProvider: DappProvider {
    static let namespace = DappNamespace.cardano

    private(set) var handled: [String] = []

    nonisolated func isConnectRequest(method: String, params: JSONValue) -> Bool {
        method == "enable" && params["quiet"]?.boolValue != true
    }

    func handle(method: String, params: JSONValue, context: DappRequestContext) async throws(DappError) -> JSONValue {
        handled.append(method)
        return .bool(true)
    }

    nonisolated func sessionDidChange(_ session: DappSessionSnapshot) -> [DappEvent] { [] }

    nonisolated func wireError(_ error: DappError) -> JSONValue {
        .object(["error": .string("\(error)")])
    }
}

/// The same shape under `solana`, for pages that connect on two chains at once.
private actor SolanaConnectProvider: DappProvider {
    static let namespace = DappNamespace.solana

    nonisolated func isConnectRequest(method: String, params: JSONValue) -> Bool { method == "connect" }

    func handle(method: String, params: JSONValue, context: DappRequestContext) async throws(DappError) -> JSONValue {
        .bool(true)
    }

    nonisolated func sessionDidChange(_ session: DappSessionSnapshot) -> [DappEvent] { [] }

    nonisolated func wireError(_ error: DappError) -> JSONValue {
        .object(["error": .string("\(error)")])
    }
}

/// Answers the account chooser by picking each chain's preselected account
/// (or the account preset for it), or declines.
private actor ChooserApproving: DappApproving {
    private let choices: [DappNamespace: ReefrWallet.Account]
    private let declines: Bool
    /// Chains the user leaves "Not connected".
    private let notConnected: Set<DappNamespace>
    private(set) var prompts: [[DappAccountSelection]] = []

    init(choice: ReefrWallet.Account?, notConnected: Set<DappNamespace> = []) {
        choices = choice.map { [.cardano: $0] } ?? [:]
        declines = choice == nil && notConnected.isEmpty
        self.notConnected = notConnected
    }

    func approve(_ request: DappApprovalRequest) async -> DappApprovalResult { .approved }

    func chooseAccounts(origin: String, selections: [DappAccountSelection]) async -> [DappNamespace: ReefrWallet.Account]? {
        prompts.append(selections)
        guard !declines else {
            return nil
        }

        return Dictionary(uniqueKeysWithValues: selections.filter { !notConnected.contains($0.namespace) }.map {
            ($0.namespace, choices[$0.namespace] ?? $0.defaultChoice.account)
        })
    }

    var offered: [[DappAccountChoice]] { prompts.flatMap { $0.map(\.choices) } }
}

private struct FixedAccounts: DappAccountSource {
    let choices: [DappAccountChoice]
    var byNamespace: [DappNamespace: [DappAccountChoice]] = [:]

    func choices(for namespace: DappNamespace) async -> [DappAccountChoice] {
        byNamespace[namespace] ?? choices
    }
}

private actor RecordingPersistence: DappPermissionPersisting {
    var stored: Set<DappSession.Permission> = []
    private(set) var noted: [DappNamespace] = []

    func loadPermissions(origin: String) async -> Set<DappSession.Permission> { stored }

    func set(_ permissions: Set<DappSession.Permission>) {
        stored = permissions
    }

    func savePermissions(origin: String, permissions: Set<DappSession.Permission>) async {
        stored = permissions
    }

    func noteConnectRequest(origin: String, namespace: DappNamespace) async {
        noted.append(namespace)
    }
}

@MainActor
private struct Fixture {
    let cardano: ReefrWallet.Account
    let other: ReefrWallet.Account
    let evm: ReefrWallet.Account

    static func make() async throws -> Fixture {
        let databaseService = try makeDatabaseService()
        let keyStoreId = try await databaseService.insertKeyStore(
            KeyStore(deviceId: nil, kind: .watchOnly, name: "Selection Test Key Store", transport: nil, vendor: nil)
        )

        func make(_ name: String, _ blockchain: Blockchain, _ address: String) -> ReefrWallet.Account {
            ReefrWallet.Account(
                address: address, blockchain: blockchain, derivationPath: nil, keyStoreId: keyStoreId, name: name
            )
        }

        return Fixture(
            cardano: make("Cardano #1", .cardano(.preprod), "cardano:preprod:xpub-one"),
            other: make("Cardano #2", .cardano(.preprod), "cardano:preprod:xpub-two"),
            evm: make("Ethereum #1", .evm(.ethereum(.sepolia)), "0x000000000000000000000000000000000000aa")
        )
    }

    func choices() -> [DappAccountChoice] {
        [cardano, other].map { DappAccountChoice(account: $0, keyStoreName: "Key") }
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct DappAccountSelectionTests {
    private let origin = "https://dapp.example"

    private func bridge(
        session: DappSession,
        approving: any DappApproving,
        accounts: [DappAccountChoice],
        provider: ConnectProvider = ConnectProvider(),
        byNamespace: [DappNamespace: [DappAccountChoice]] = [:]
    ) -> DappBridge {
        DappBridge(
            providers: [provider, SolanaConnectProvider()],
            session: session,
            approving: approving,
            signingService: DappSigningService(),
            accounts: FixedAccounts(choices: accounts, byNamespace: byNamespace)
        )
    }

    @Test func reloadingPicksUpGrantsChangedWhileTheWindowWasOpen() async throws {
        let fixture = try await Fixture.make()
        let persistence = RecordingPersistence()
        let session = DappSession(origin: origin, persistence: persistence)
        await persistence.set([.init(origin: origin, namespace: .cardano, accountAddress: fixture.cardano.address)])
        await session.restorePermissions()
        #expect(await session.grantedAddress(.cardano) == fixture.cardano.address)

        // The dapp's settings now hold Ethereum instead of Cardano.
        await persistence.set([.init(origin: origin, namespace: .ethereum, accountAddress: fixture.evm.address)])
        await session.reloadPermissions()

        #expect(await session.grantedAddress(.ethereum) == fixture.evm.address)
        #expect(await session.grantedAddress(.cardano) == nil)
    }

    private func enable(_ bridge: DappBridge, params: JSONValue = .array([])) async -> DappBridge.DispatchOutcome {
        await bridge.dispatch(namespaceRaw: "cardano", method: "enable", params: params, origin: origin)
    }

    @Test func aMismatchedChainAsksWhichAccountAndConnectsWithIt() async throws {
        let fixture = try await Fixture.make()
        let session = DappSession(origin: origin)
        await session.setActiveAccount(fixture.evm)
        let approving = ChooserApproving(choice: fixture.other)
        let provider = ConnectProvider()

        let outcome = await enable(
            bridge(session: session, approving: approving, accounts: fixture.choices(), provider: provider)
        )

        #expect(outcome == .success(.bool(true)))
        #expect(await approving.offered.count == 1)
        #expect(await session.selectedAccount(.cardano) == fixture.other)
        // Choosing is the consent: the provider finds the permission and the account in place.
        #expect(await session.isPermitted(.cardano))
        #expect(await provider.handled == ["enable"])
    }

    @Test func decliningTheChooserRejectsWithoutReachingTheProvider() async throws {
        let fixture = try await Fixture.make()
        let session = DappSession(origin: origin)
        await session.setActiveAccount(fixture.evm)
        let provider = ConnectProvider()

        let outcome = await enable(
            bridge(session: session, approving: ChooserApproving(choice: nil), accounts: fixture.choices(), provider: provider)
        )

        #expect(outcome == .providerError(.object(["error": .string("userRejected")])))
        #expect(await provider.handled.isEmpty)
        #expect(await session.selectedAccount(.cardano) == nil)
    }

    @Test func theRememberedAccountIsSelectedWithoutAsking() async throws {
        let fixture = try await Fixture.make()
        let persistence = RecordingPersistence()
        await persistence.savePermissions(
            origin: origin,
            permissions: [.init(origin: origin, namespace: .cardano, accountAddress: fixture.other.address)]
        )
        let session = DappSession(origin: origin, persistence: persistence)
        await session.restorePermissions()
        await session.setActiveAccount(fixture.evm)
        let approving = ChooserApproving(choice: fixture.cardano)

        let outcome = await enable(bridge(session: session, approving: approving, accounts: fixture.choices()))

        #expect(outcome == .success(.bool(true)))
        #expect(await approving.offered.isEmpty)
        #expect(await session.selectedAccount(.cardano) == fixture.other)
    }

    @Test func noAccountsOnTheChainIsDisconnected() async throws {
        let fixture = try await Fixture.make()
        let session = DappSession(origin: origin)
        await session.setActiveAccount(fixture.evm)

        let outcome = await enable(bridge(session: session, approving: ChooserApproving(choice: nil), accounts: []))

        #expect(outcome == .providerError(.object(["error": .string("disconnected")])))
    }

    @Test func aQuietCheckNeverPromptsButStillCountsAsUsingTheChain() async throws {
        let fixture = try await Fixture.make()
        let persistence = RecordingPersistence()
        let session = DappSession(origin: origin, persistence: persistence)
        await session.setActiveAccount(fixture.evm)
        let approving = ChooserApproving(choice: fixture.cardano)

        _ = await enable(
            bridge(session: session, approving: approving, accounts: fixture.choices()),
            params: .object(["quiet": .bool(true)])
        )

        #expect(await approving.offered.isEmpty)
        #expect(await persistence.noted.isEmpty)
    }

    @Test func aConnectRequestRecordsTheChainTheDappAskedFor() async throws {
        let fixture = try await Fixture.make()
        let persistence = RecordingPersistence()
        let session = DappSession(origin: origin, persistence: persistence)
        await session.setActiveAccount(fixture.cardano)

        _ = await enable(bridge(session: session, approving: ChooserApproving(choice: nil), accounts: fixture.choices()))

        #expect(await persistence.noted == [.cardano])
    }

    @Test func aFirstConnectOnTheSelectedChainStillShowsTheChooser() async throws {
        let fixture = try await Fixture.make()
        let session = DappSession(origin: origin)
        await session.setActiveAccount(fixture.cardano)
        let approving = ChooserApproving(choice: nil)

        _ = await enable(bridge(session: session, approving: approving, accounts: fixture.choices()))

        let prompts = await approving.prompts
        #expect(prompts.count == 1)
        // The selected account is preselected.
        #expect(prompts.first?.first?.defaultAddress == fixture.cardano.address)
    }

    @Test func connectRequestsMadeTogetherShareOnePrompt() async throws {
        let fixture = try await Fixture.make()
        let session = DappSession(origin: origin)
        await session.setActiveAccount(fixture.evm)
        let approving = ChooserApproving(choice: fixture.other)
        let solana = fixture.evm // stands in for a Solana account in the offered list
        let bridge = bridge(
            session: session,
            approving: approving,
            accounts: fixture.choices(),
            byNamespace: [.solana: [DappAccountChoice(account: solana, keyStoreName: "Key")]]
        )

        async let first = enable(bridge)
        async let second = bridge.dispatch(namespaceRaw: "solana", method: "connect", params: .array([]), origin: origin)
        let (cardano, sol) = await (first, second)

        #expect(cardano == .success(.bool(true)))
        #expect(sol == .success(.bool(true)))
        let prompts = await approving.prompts
        #expect(prompts.count == 1)
        #expect(Set(prompts[0].map(\.namespace)) == [.cardano, .solana])
        #expect(await session.grantedAddress(.solana) == solana.address)
    }

    @Test func aChainLeftNotConnectedIsRefusedButStillRecordedForTheDapp() async throws {
        let fixture = try await Fixture.make()
        let persistence = RecordingPersistence()
        let session = DappSession(origin: origin, persistence: persistence)
        await session.setActiveAccount(fixture.evm)
        let approving = ChooserApproving(choice: nil, notConnected: [.solana])
        let bridge = bridge(
            session: session,
            approving: approving,
            accounts: fixture.choices(),
            byNamespace: [.solana: [DappAccountChoice(account: fixture.evm, keyStoreName: "Key")]]
        )

        async let first = enable(bridge)
        async let second = bridge.dispatch(namespaceRaw: "solana", method: "connect", params: .array([]), origin: origin)
        let (cardano, sol) = await (first, second)

        #expect(cardano == .success(.bool(true)))
        #expect(sol == .providerError(.object(["error": .string("userRejected")])))
        #expect(await session.grantedAddress(.solana) == nil)
        // Both chains are on the dapp's entry, so its pane offers a selector for each.
        #expect(Set(await persistence.noted) == [.cardano, .solana])
    }

    @Test func choicesAreLabelledLikeTheAccountHeader() async throws {
        let fixture = try await Fixture.make()

        let long = DappAccountChoice(account: fixture.evm, keyStoreName: "Trezor Safe 5").label
        let unnamed = DappAccountChoice(account: fixture.evm, keyStoreName: "").label

        #expect(long == "Trezor Safe 5 · Ethereum #1 (0x00000000…0000aa)")
        #expect(unnamed == "Ethereum #1 (0x00000000…0000aa)")
    }

    @Test func everyConnectedChainIsServedWhileTheToolbarShowsOne() async throws {
        let fixture = try await Fixture.make()
        let persistence = RecordingPersistence()
        await persistence.savePermissions(
            origin: origin,
            permissions: [
                .init(origin: origin, namespace: .cardano, accountAddress: fixture.cardano.address),
                .init(origin: origin, namespace: .solana, accountAddress: fixture.evm.address)
            ]
        )
        let session = DappSession(origin: origin, persistence: persistence)
        await session.restorePermissions()
        await session.setActiveAccount(fixture.cardano)

        // The chain on screen is Cardano, yet a Solana connect request finds its remembered account.
        let bridge = bridge(
            session: session,
            approving: ChooserApproving(choice: nil),
            accounts: fixture.choices(),
            byNamespace: [.solana: [DappAccountChoice(account: fixture.evm, keyStoreName: "Key")]]
        )
        let outcome = await bridge.dispatch(namespaceRaw: "solana", method: "connect", params: .array([]), origin: origin)

        #expect(outcome == .success(.bool(true)))
        #expect(await session.selectedAccount(.solana) == fixture.evm)
        #expect(await session.selectedAccount(.cardano) == fixture.cardano)
        #expect(await session.activeAccount == fixture.cardano)
    }

    @Test func aDappAlreadyConnectedWithTheSelectedAccountIsNotAskedAgain() async throws {
        let fixture = try await Fixture.make()
        let session = DappSession(origin: origin)
        await session.setActiveAccount(fixture.cardano)
        _ = await session.grantConnection(.cardano, origin: origin, account: fixture.cardano)
        let approving = ChooserApproving(choice: fixture.other)

        let outcome = await enable(bridge(session: session, approving: approving, accounts: fixture.choices()))

        #expect(outcome == .success(.bool(true)))
        #expect(await approving.offered.isEmpty)
        #expect(await session.selectedAccount(.cardano) == fixture.cardano)
    }
}

// MARK: - Store

@MainActor
@Suite
struct ConnectedDappRequestedChainsTests {
    private func store() throws -> (ConnectedDappStore, ModelContainer) {
        let container = try ModelContainer(
            for: ConnectedDappModel.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )

        return (ConnectedDappStore(modelContainer: container), container)
    }

    @Test func chainsRequestedBeforeAnApprovalAreSavedWhenTheDappIsFirstConnected() async throws {
        let (store, container) = try store()

        await store.noteConnectRequest(origin: "https://dapp.example:0", namespace: .cardano)
        await store.noteConnectRequest(origin: "https://dapp.example:0", namespace: .ethereum)
        #expect(try container.mainContext.fetch(FetchDescriptor<ConnectedDappModel>()).isEmpty)

        await store.savePermissions(
            origin: "https://dapp.example:0",
            permissions: [.init(origin: "https://dapp.example:0", namespace: .cardano, accountAddress: "cardano:x")]
        )

        let model = try #require(try container.mainContext.fetch(FetchDescriptor<ConnectedDappModel>()).first)
        #expect(model.requestedNamespaces == ["cardano", "ethereum"])
    }

    @Test func chainsRequestedOnAnExistingDappAreAddedOnce() async throws {
        let (store, _) = try store()
        let url = try #require(URL(string: "https://dapp.example"))
        let model = store.addBrowserDapp(url: url)

        await store.noteConnectRequest(origin: model.origin, namespace: .tron)
        await store.noteConnectRequest(origin: model.origin, namespace: .tron)

        #expect(model.requestedNamespaces == ["tron"])
    }

    @Test func theSelectedAccountIsSavedPerDappAndRestored() async throws {
        let (store, _) = try store()
        let fixture = try await Fixture.make()
        let url = try #require(URL(string: "https://dapp.example"))
        let model = store.addBrowserDapp(url: url)
        let session = DappSession(origin: model.origin, persistence: store)

        await session.setActiveAccount(fixture.other)
        #expect(model.selectedAccountAddress == fixture.other.address)

        let reopened = DappSession(origin: model.origin, persistence: store)
        await reopened.restorePermissions()
        #expect(await reopened.rememberedAddress() == fixture.other.address)
    }

    @Test func connectingFromTheDetailsPaneSetsTheGrantAndTheSelection() throws {
        let (store, _) = try store()
        let model = store.addBrowserDapp(url: try #require(URL(string: "https://dapp.example")))

        store.connect(model, accountAddress: "cardano:one", namespace: "cardano")
        #expect(model.selectedAccountAddress == "cardano:one")
        #expect(model.grants == [ConnectedDappGrant(accountAddress: "cardano:one", namespace: "cardano")])

        store.connect(model, accountAddress: nil, namespace: nil)
        #expect(model.selectedAccountAddress == nil)
        #expect(model.grants.isEmpty)
    }

    @Test func disconnectingOneChainLeavesTheOthersAndForgetsItsRememberedAccount() throws {
        let (store, _) = try store()
        let model = store.addBrowserDapp(url: try #require(URL(string: "https://dapp.example")))
        store.connect(model, accountAddress: "0xaa", namespace: "ethereum")
        store.connect(model, accountAddress: "sol1", namespace: "solana")
        store.select(model, accountAddress: "0xaa")

        store.disconnect(model, namespace: "ethereum")

        #expect(model.grants == [ConnectedDappGrant(accountAddress: "sol1", namespace: "solana")])
        #expect(model.selectedAccountAddress == nil)

        store.select(model, accountAddress: "sol1")
        store.disconnect(model, namespace: "ethereum")
        #expect(model.selectedAccountAddress == "sol1")
    }

    @Test func theDetailsPaneCanPointAChainAtAnotherAccountOrDisconnectIt() throws {
        let (store, _) = try store()
        let url = try #require(URL(string: "https://dapp.example"))
        let model = store.addBrowserDapp(url: url)

        store.setGrant(model, namespace: "cardano", accountAddress: "cardano:one")
        store.setGrant(model, namespace: "ethereum", accountAddress: "0xaa")
        store.setGrant(model, namespace: "cardano", accountAddress: "cardano:two")
        #expect(model.grants == [
            ConnectedDappGrant(accountAddress: "cardano:two", namespace: "cardano"),
            ConnectedDappGrant(accountAddress: "0xaa", namespace: "ethereum")
        ])

        store.setGrant(model, namespace: "cardano", accountAddress: nil)
        #expect(model.grants == [ConnectedDappGrant(accountAddress: "0xaa", namespace: "ethereum")])
    }
}

struct BrowserWindowTargetTests {
    @Test func eachDappAndChainCombinationIsItsOwnWindow() throws {
        let url = try #require(URL(string: "https://app.uniswap.org"))

        let ethereum = BrowserWindowTarget(url: url, namespace: .ethereum)
        let solana = BrowserWindowTarget(url: url, namespace: .solana)

        #expect(ethereum != solana)
        #expect(ethereum != BrowserWindowTarget(url: url))
        #expect(ethereum == BrowserWindowTarget(url: url, namespace: .ethereum))
        #expect(Set([ethereum, solana, BrowserWindowTarget(url: url)]).count == 3)
    }

    @Test func aTargetSurvivesEncodingAsWindowStateDoes() throws {
        let target = BrowserWindowTarget(url: try #require(URL(string: "https://dapp.example")), namespace: .cardano)

        let decoded = try JSONDecoder().decode(BrowserWindowTarget.self, from: JSONEncoder().encode(target))

        #expect(decoded == target)
        #expect(decoded.namespace == "cardano")
    }
}

@MainActor
struct BrowserAccountCapsuleTests {
    private func choice(_ name: String, _ blockchain: Blockchain, address: String, key: String = "Trezor 5") async throws -> DappAccountChoice {
        let databaseService = try makeDatabaseService()
        let keyStoreId = try await databaseService.insertKeyStore(
            KeyStore(deviceId: nil, kind: .watchOnly, name: key, transport: nil, vendor: nil)
        )

        return DappAccountChoice(
            account: ReefrWallet.Account(
                address: address, blockchain: blockchain, derivationPath: nil, keyStoreId: keyStoreId, name: name
            ),
            keyStoreName: key
        )
    }

    @Test func theCapsuleSaysNotConnectedUntilConnectedThenNamesTheAccountOrSummarisesSeveral() async throws {
        let evm = try await choice("Arbitrum #3", .evm(.arbitrum(.mainnet)), address: "0x000000000000000000000000000000000000aa")
        let solana = try await choice("Solana #1", .solana(.mainnet), address: "SolanaTestAddress1")

        #expect(BrowserAccountSelector.label(for: []) == "Not Connected")
        #expect(BrowserAccountSelector.label(for: [evm]) == "Trezor 5 · Arbitrum #3 (0x00000000…0000aa)")
        #expect(BrowserAccountSelector.label(for: [evm, solana]) == "2 accounts (Arbitrum, Solana)")
    }
}
