import Foundation
import SwiftData
import Testing
@testable import ReefrWallet

@MainActor
@Suite
struct DappDisconnectTests {
    @Test
    func disconnectSessionsDropsSessionsApprovedWithAddresses() async throws {
        let databaseService = try makeDatabaseService()
        let client = FakeWalletConnectClient(
            sessions: [Self.session(topic: "keep", address: "0xkeep"), Self.session(topic: "drop", address: "0xdrop")]
        )

        let service = WalletConnectService(
            client: client,
            databaseService: databaseService,
            signingService: DappSigningService(transactionService: TransactionService(databaseService: databaseService))
        )

        service.start()
        await service.disconnectSessions(addresses: ["0xdrop"])

        #expect(client.disconnectedTopics == ["drop"])
        #expect(service.sessions.map(\.topic) == ["keep"])
    }

    @Test
    func revokeGrantsDropsOnlyMatchingGrants() throws {
        let container = try ModelContainer(
            for: ConnectedDappModel.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )

        let store = ConnectedDappStore(modelContainer: container)
        let kept = ConnectedDappGrant(accountAddress: "0xkeep", namespace: "ethereum")
        let dropped = ConnectedDappGrant(accountAddress: "0xdrop", namespace: "ethereum")
        let first = try #require(URL(string: "https://one.example"))
        let second = try #require(URL(string: "https://two.example"))

        store.addBrowserDapp(url: first).grants = [dropped, kept]
        store.addBrowserDapp(url: second).grants = [kept]

        store.revokeGrants(addresses: ["0xdrop"])

        let models = try container.mainContext.fetch(FetchDescriptor<ConnectedDappModel>())
        let grants = Dictionary(uniqueKeysWithValues: models.map { ($0.urlString, $0.grants) })
        #expect(grants[first.absoluteString] == [kept])
        #expect(grants[second.absoluteString] == [kept])
    }

    private static func session(topic: String, address: String) -> WalletConnectSessionInfo {
        WalletConnectSessionInfo(
            accounts: [WalletConnectAccountRef(address: address, chain: "eip155:1")],
            expiry: .distantFuture,
            iconURL: nil,
            name: topic,
            topic: topic,
            url: "https://\(topic).example"
        )
    }
}

@MainActor
private final class FakeWalletConnectClient: WalletConnectClient {
    var onProposal: ((WalletConnectProposal) -> Void)?
    var onRequest: ((WalletConnectRequest) -> Void)?
    var onSessions: (([WalletConnectSessionInfo]) -> Void)?

    private(set) var disconnectedTopics: [String] = []
    private let storedSessions: [WalletConnectSessionInfo]

    init(sessions: [WalletConnectSessionInfo]) {
        storedSessions = sessions
    }

    func approve(proposalId: String, namespaces: [WalletConnectApprovedNamespace]) async throws {}

    func configure() {}

    func disconnect(topic: String) async throws {
        disconnectedTopics.append(topic)
    }

    func pair(uri: String) async throws {}

    func reject(proposalId: String) async throws {}

    func respond(topic: String, requestId: String, result: Result<Data, WalletConnectRPCError>) async throws {}

    func sessions() -> [WalletConnectSessionInfo] {
        storedSessions
    }
}
