// Unit tests for the chain-agnostic dapp bridge core (DappBridge/
// DappSession) — dispatch by namespace, unknown namespace/method
// rejection, origin-change permission clearing, and serialized
// approvals. Uses a fake DappProvider registered under the `ethereum`
// namespace as a stand-in for a real chain provider, and a stub
// DappApproving that answers immediately — no WebKit round trip, since
// WKScriptMessage has no public initializer (see DappBridge.dispatch's
// doc comment for why the dispatch core is factored out separately).

import Foundation
import SwiftData
import Testing
@testable import ReefrWallet

// MARK: - Test doubles

/// Registered under the `ethereum` namespace as a stand-in for
/// `EthereumDappProvider` — an actor since `DappProvider` requires
/// `Sendable`, but `handle(method:params:context:)` is already `async`
/// so callers always `await` it regardless.
private actor FakeDappProvider: DappProvider {
    static let namespace = DappNamespace.ethereum

    private(set) var handledMethods: [String] = []
    var resultForMethod: [String: JSONValue] = [:]
    var errorForMethod: [String: DappError] = [:]

    func handle(method: String, params: JSONValue, context: DappRequestContext) async throws(DappError) -> JSONValue {
        handledMethods.append(method)
        if let error = errorForMethod[method] {
            throw error
        }

        return resultForMethod[method] ?? .null
    }

    nonisolated func sessionDidChange(_ session: DappSessionSnapshot) -> [DappEvent] {
        []
    }

    nonisolated func wireError(_ error: DappError) -> JSONValue {
        .object(["code": .number(-1), "message": .string("\(error)")])
    }
}

/// Answers every approval request immediately with a preset result.
private struct StubApproving: DappApproving {
    let result: DappApprovalResult

    func approve(_ request: DappApprovalRequest) async -> DappApprovalResult {
        result
    }
}

/// Records `String` entries in call order, from possibly-concurrent tasks.
private actor OrderLog {
    private(set) var entries: [String] = []

    func append(_ entry: String) {
        entries.append(entry)
    }
}

private func makeTestAccount(
    databaseService: DatabaseService, address: String = "0x000000000000000000000000000000000000aa"
) async throws -> ReefrWallet.Account {
    let keyStoreId = try await databaseService.insertKeyStore(
        KeyStore(deviceId: nil, kind: .watchOnly, name: "Dapp Bridge Test Key Store", transport: nil, vendor: nil)
    )

    return Account(
        accountIndex: 0,
        address: address,
        blockchain: .evm(.ethereum(.sepolia)),
        derivationPath: nil,
        keyStoreId: keyStoreId,
        name: "Dapp Bridge Test Account"
    )
}

// MARK: - Dispatch by namespace

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct DappBridgeTests {
    @Test
    func dispatchRoutesToTheRegisteredNamespacesProvider() async throws {
        let databaseService = try makeDatabaseService()
        let session = DappSession(origin: "https://example.com")
        let account = try await makeTestAccount(databaseService: databaseService)
        await session.setActiveAccount(account)

        let provider = FakeDappProvider()
        await provider.setResult(.string("0x1"), for: "eth_chainId")

        let bridge = DappBridge(
            providers: [provider], session: session, approving: StubApproving(result: .approved),
            signingService: DappSigningService()
        )

        let outcome = await bridge.dispatch(
            namespaceRaw: "ethereum", method: "eth_chainId", params: .array([]), origin: "https://example.com"
        )

        #expect(outcome == .success(.string("0x1")))
        #expect(await provider.handledMethods == ["eth_chainId"])
    }

    @Test
    func dispatchRejectsAnUnknownNamespace() async throws {
        let session = DappSession(origin: "https://example.com")
        let bridge = DappBridge(
            providers: [FakeDappProvider()], session: session, approving: StubApproving(result: .approved),
            signingService: DappSigningService()
        )

        let outcome = await bridge.dispatch(
            namespaceRaw: "solana", method: "connect", params: .array([]), origin: "https://example.com"
        )

        guard case let .transportError(message) = outcome else {
            Issue.record("expected a transportError, got \(outcome)")
            return
        }
        #expect(message.contains("solana"))
    }

    @Test
    func dispatchMapsAProviderThrownErrorToAProviderError() async throws {
        let session = DappSession(origin: "https://example.com")
        let provider = FakeDappProvider()
        await provider.setError(.unsupportedMethod, for: "eth_sign")

        let bridge = DappBridge(
            providers: [provider], session: session, approving: StubApproving(result: .approved),
            signingService: DappSigningService()
        )

        let outcome = await bridge.dispatch(
            namespaceRaw: "ethereum", method: "eth_sign", params: .array([]), origin: "https://example.com"
        )

        guard case let .providerError(wireError) = outcome else {
            Issue.record("expected a providerError, got \(outcome)")
            return
        }
        #expect(wireError["message"]?.stringValue?.contains("unsupportedMethod") == true)
    }

    // MARK: - Origin changes

    @Test
    func dispatchClearsPermissionsWhenTheOriginChanges() async throws {
        let databaseService = try makeDatabaseService()
        let session = DappSession(origin: "https://a.example")
        let account = try await makeTestAccount(databaseService: databaseService)
        await session.setActiveAccount(account)
        #expect(await session.grantPermission(.ethereum, origin: session.origin, account: account))
        #expect(await session.isPermitted(.ethereum))

        let bridge = DappBridge(
            providers: [FakeDappProvider()], session: session, approving: StubApproving(result: .approved),
            signingService: DappSigningService()
        )

        _ = await bridge.dispatch(
            namespaceRaw: "ethereum", method: "eth_chainId", params: .array([]), origin: "https://b.example"
        )

        #expect(await session.origin == "https://b.example")
        #expect(await session.isPermitted(.ethereum) == false)
        // The selected account deliberately carries over across an origin
        // change — it's controlled by the browser's own account picker,
        // not by which page is loaded (see `DappSession.updateOrigin`'s
        // doc comment). Only the permission grant is origin-scoped.
        #expect(await session.selectedAccount(.ethereum) == account)
    }

    @Test
    func dispatchLeavesPermissionsIntactWhenTheOriginIsUnchanged() async throws {
        let databaseService = try makeDatabaseService()
        let session = DappSession(origin: "https://a.example")
        let account = try await makeTestAccount(databaseService: databaseService)
        await session.setActiveAccount(account)
        #expect(await session.grantPermission(.ethereum, origin: session.origin, account: account))

        let bridge = DappBridge(
            providers: [FakeDappProvider()], session: session, approving: StubApproving(result: .approved),
            signingService: DappSigningService()
        )

        _ = await bridge.dispatch(
            namespaceRaw: "ethereum", method: "eth_chainId", params: .array([]), origin: "https://a.example"
        )

        #expect(await session.isPermitted(.ethereum))
    }

    // MARK: - Serialized approvals

    @Test
    func approvalsAreSerializedAcrossConcurrentCallers() async throws {
        let session = DappSession(origin: "https://example.com")
        let log = OrderLog()

        async let first: Void = session.withExclusiveApproval {
            await log.append("first-start")
            try? await Task.sleep(for: .milliseconds(50))
            await log.append("first-end")
        }

        // Give `first` a head start so it reliably acquires the slot before `second` tries.
        try await Task.sleep(for: .milliseconds(10))

        async let second: Void = session.withExclusiveApproval {
            await log.append("second-start")
            await log.append("second-end")
        }

        _ = await (first, second)
        #expect(await log.entries == ["first-start", "first-end", "second-start", "second-end"])
    }
}

private extension FakeDappProvider {
    func setResult(_ result: JSONValue, for method: String) {
        resultForMethod[method] = result
    }

    func setError(_ error: DappError, for method: String) {
        errorForMethod[method] = error
    }
}
