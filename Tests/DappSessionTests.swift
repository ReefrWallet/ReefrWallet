// Actor-level unit tests for DappSession's single-active-account model
// (ADR-024) — permission carry-forward across account switches within
// and across namespaces, revocation, and origin changes. No provider
// or bridge indirection: DappSession's public API is exercised directly.

import Foundation
import Testing
import WalletKit
@testable import ReefrWallet

private func makeTestAccount(
    databaseService: DatabaseService,
    blockchain: Blockchain = .evm(.ethereum(.sepolia)),
    address: String = "0x000000000000000000000000000000000000aa"
) async throws -> ReefrWallet.Account {
    let keyStoreId = try await databaseService.insertKeyStore(
        KeyStore(deviceId: nil, kind: .watchOnly, name: "Dapp Session Test Key Store", transport: nil, vendor: nil)
    )

    return Account(
        accountIndex: 0,
        address: address,
        blockchain: blockchain,
        derivationPath: nil,
        keyStoreId: keyStoreId,
        name: "Dapp Session Test Account"
    )
}

@Suite(.timeLimit(.minutes(1)))
struct DappSessionTests {
    @Test
    func carryForwardWithinOneNamespace() async throws {
        let databaseService = try makeDatabaseService()
        let session = DappSession(origin: "https://dapp.example")

        let accountA = try await makeTestAccount(
            databaseService: databaseService, address: "0x00000000000000000000000000000000000001"
        )

        let accountB = try await makeTestAccount(
            databaseService: databaseService, address: "0x00000000000000000000000000000000000002"
        )

        await session.setActiveAccount(accountA)
        #expect(await session.grantPermission(.ethereum, origin: session.origin, account: accountA))
        #expect(await session.isPermitted(.ethereum))

        await session.setActiveAccount(accountB)
        #expect(await session.selectedAccount(.ethereum) == accountB)
        #expect(await session.isPermitted(.ethereum))
    }

    @Test
    func noCarryForwardWithoutAPriorGrant() async throws {
        let databaseService = try makeDatabaseService()
        let session = DappSession(origin: "https://dapp.example")

        let accountA = try await makeTestAccount(
            databaseService: databaseService, address: "0x00000000000000000000000000000000000001"
        )

        let accountB = try await makeTestAccount(
            databaseService: databaseService, address: "0x00000000000000000000000000000000000002"
        )

        await session.setActiveAccount(accountA)
        #expect(await session.isPermitted(.ethereum) == false)

        await session.setActiveAccount(accountB)
        #expect(await session.isPermitted(.ethereum) == false)
    }

    /// The one test that proves the chosen design: under the old
    /// per-namespace model, "carry forward" meant "the immediately
    /// previous account in this slot was permitted." With one slot,
    /// that question has no stable answer across a detour through
    /// another namespace, so `setActiveAccount` instead asks "does this
    /// namespace hold any grant at this origin at all" — which this
    /// detour-and-return exercises directly.
    @Test
    func aDetourThroughAnotherNamespaceAndBackStaysPermitted() async throws {
        let databaseService = try makeDatabaseService()
        let session = DappSession(origin: "https://dapp.example")

        let ethereumAccount = try await makeTestAccount(
            databaseService: databaseService, blockchain: .evm(.ethereum(.sepolia)),
            address: "0x00000000000000000000000000000000000001"
        )

        let solanaAccount = try await makeTestAccount(
            databaseService: databaseService, blockchain: .solana(.devnet), address: "SolanaTestAddress1"
        )

        let ethereumAccount2 = try await makeTestAccount(
            databaseService: databaseService, blockchain: .evm(.ethereum(.sepolia)),
            address: "0x00000000000000000000000000000000000002"
        )

        await session.setActiveAccount(ethereumAccount)
        #expect(await session.grantPermission(.ethereum, origin: session.origin, account: ethereumAccount))
        #expect(await session.isPermitted(.ethereum))

        await session.setActiveAccount(solanaAccount)
        #expect(await session.selectedAccount(.ethereum) == nil)
        #expect(await session.isPermitted(.ethereum) == false)
        #expect(await session.isPermitted(.solana) == false) // no grant for Solana yet

        await session.setActiveAccount(ethereumAccount2)
        #expect(await session.selectedAccount(.ethereum) == ethereumAccount2)
        #expect(await session.isPermitted(.ethereum)) // restored without a new prompt
    }

    @Test
    func revokePermissionWipesEveryAddressNotJustTheCurrentOne() async throws {
        let databaseService = try makeDatabaseService()
        let session = DappSession(origin: "https://dapp.example")

        let accountA = try await makeTestAccount(
            databaseService: databaseService, address: "0x00000000000000000000000000000000000001"
        )

        let accountB = try await makeTestAccount(
            databaseService: databaseService, address: "0x00000000000000000000000000000000000002"
        )

        await session.setActiveAccount(accountA)
        #expect(await session.grantPermission(.ethereum, origin: session.origin, account: accountA))
        await session.setActiveAccount(accountB)
        #expect(await session.isPermitted(.ethereum)) // carried forward to accountB

        await session.revokePermission(.ethereum)
        #expect(await session.isPermitted(.ethereum) == false)

        await session.setActiveAccount(accountA)
        #expect(await session.isPermitted(.ethereum) == false) // accountA's grant was wiped too
    }

    @Test
    func updateOriginClearsPermissionsButKeepsTheActiveAccount() async throws {
        let databaseService = try makeDatabaseService()
        let session = DappSession(origin: "https://a.example")
        let account = try await makeTestAccount(databaseService: databaseService)

        await session.setActiveAccount(account)
        #expect(await session.grantPermission(.ethereum, origin: session.origin, account: account))
        #expect(await session.isPermitted(.ethereum))

        await session.updateOrigin("https://b.example")

        #expect(await session.isPermitted(.ethereum) == false)
        #expect(await session.selectedAccount(.ethereum) == account)
    }

    @Test
    func clearActiveAccountRemovesTheSelectionFromEveryNamespace() async throws {
        let databaseService = try makeDatabaseService()
        let session = DappSession(origin: "https://dapp.example")
        let account = try await makeTestAccount(databaseService: databaseService)

        await session.setActiveAccount(account)
        #expect(await session.grantPermission(.ethereum, origin: session.origin, account: account))

        await session.clearActiveAccount()

        #expect(await session.activeAccount == nil)
        #expect(await session.activeNamespace == nil)
        #expect(await session.selectedAccount(.ethereum) == nil)
        // Clearing the selection (e.g. the account was deleted) doesn't
        // itself revoke the dapp's existing grant — only
        // `revokePermission`/`updateOrigin` do that.
        #expect(await session.permissions.contains { $0.namespace == .ethereum })
    }

    @Test
    func grantPermissionIsRefusedOnceTheOriginChanged() async throws {
        let databaseService = try makeDatabaseService()
        let session = DappSession(origin: "https://a.example")
        let account = try await makeTestAccount(databaseService: databaseService)
        await session.setActiveAccount(account)

        await session.updateOrigin("https://b.example")

        #expect(await session.grantPermission(.ethereum, origin: "https://a.example", account: account) == false)
        #expect(await session.isPermitted(.ethereum) == false)
    }

    @Test
    func grantPermissionIsRefusedOnceTheSelectedAccountChanged() async throws {
        let databaseService = try makeDatabaseService()
        let session = DappSession(origin: "https://dapp.example")

        let accountA = try await makeTestAccount(
            databaseService: databaseService, address: "0x00000000000000000000000000000000000001"
        )

        let accountB = try await makeTestAccount(
            databaseService: databaseService, address: "0x00000000000000000000000000000000000002"
        )

        await session.setActiveAccount(accountA)
        await session.setActiveAccount(accountB)

        #expect(await session.grantPermission(.ethereum, origin: "https://dapp.example", account: accountA) == false)
        #expect(await session.isPermitted(.ethereum) == false)
    }

    /// An automatic replacement must not inherit the origin's grant: the
    /// selector falls back to another account when the connected one is
    /// deleted, and the user never approved that one.
    @Test
    func noCarryForwardOnAutomaticReplacement() async throws {
        let databaseService = try makeDatabaseService()
        let session = DappSession(origin: "https://dapp.example")

        let accountA = try await makeTestAccount(
            databaseService: databaseService, address: "0x00000000000000000000000000000000000001"
        )

        let accountB = try await makeTestAccount(
            databaseService: databaseService, address: "0x00000000000000000000000000000000000002"
        )

        await session.setActiveAccount(accountA)
        #expect(await session.grantPermission(.ethereum, origin: session.origin, account: accountA))

        await session.replaceActiveAccount(accountB)
        #expect(await session.selectedAccount(.ethereum) == accountB)
        #expect(await session.isPermitted(.ethereum) == false)
    }
}
