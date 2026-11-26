import Foundation
import Testing
@testable import ReefrWallet

@MainActor
@Suite
struct WalletConnectServiceTests {
    /// Reown re-emits its oldest unanswered request whenever another arrives.
    @Test
    func aRequestReemittedWhileInFlightIsAnsweredOnce() async throws {
        let (client, service) = try Self.start()

        client.onRequest?(Self.request)
        client.onRequest?(Self.request)
        try await Self.waitForAttempts(1, client)

        #expect(client.respondAttempts == ["1"])
        withExtendedLifetime(service) {}
    }

    @Test
    func anAnswerThatFailedToSendIsSentAgainWhenReemitted() async throws {
        let (client, service) = try Self.start()
        client.failingResponds = 1

        client.onRequest?(Self.request)
        try await Self.waitForAttempts(1, client)
        #expect(service.failureMessage != nil)

        client.onRequest?(Self.request)
        try await Self.waitForAttempts(2, client)

        #expect(client.respondAttempts == ["1", "1"])
        #expect(client.respondedRequestIds == ["1"])
    }

    private static let request = WalletConnectRequest(
        chainId: "eip155:1", id: "1", method: "personal_sign", params: Data("[]".utf8), topic: "topic",
        verification: .scam
    )

    private static func start() throws -> (FakeWalletConnectClient, WalletConnectService) {
        let databaseService = try makeDatabaseService()
        let client = FakeWalletConnectClient(sessions: [])
        let service = WalletConnectService(
            client: client,
            databaseService: databaseService,
            signingService: DappSigningService(transactionService: TransactionService(databaseService: databaseService))
        )

        service.start()
        return (client, service)
    }

    private static func waitForAttempts(_ count: Int, _ client: FakeWalletConnectClient) async throws {
        for _ in 0..<500 where client.respondAttempts.count < count {
            try await Task.sleep(for: .milliseconds(10))
        }

        try await Task.sleep(for: .milliseconds(200))
    }
}

@MainActor
final class FakeWalletConnectClient: WalletConnectClient {
    var onProposal: ((WalletConnectProposal) -> Void)?
    var onRequest: ((WalletConnectRequest) -> Void)?
    var onSessions: (([WalletConnectSessionInfo]) -> Void)?

    private(set) var disconnectedTopics: [String] = []
    var failingResponds = 0
    private(set) var respondAttempts: [String] = []
    private(set) var respondedRequestIds: [String] = []
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

    func respond(topic: String, requestId: String, result: Result<Data, WalletConnectRPCError>) async throws {
        respondAttempts.append(requestId)

        if failingResponds > 0 {
            failingResponds -= 1
            throw URLError(.notConnectedToInternet)
        }

        respondedRequestIds.append(requestId)
    }

    func sessions() -> [WalletConnectSessionInfo] {
        storedSessions
    }
}
