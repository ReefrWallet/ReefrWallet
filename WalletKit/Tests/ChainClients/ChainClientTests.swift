// Spec-driven test for Docs/Design Specification/ChainClients/ChainClient.swift.
// Will compile once the corresponding type is exported from Sources.
//
// No real chain crate exists yet, so this exercises the protocol's shape
// through a local mock rather than a real (e.g. Bitcoin/Ethereum) client.

import Testing
@testable import WalletKit

private struct MockChainClient: ChainClient {
    typealias Address = String

    let blockchain: Blockchain
    let addressForAccount: (Account) -> String

    func deriveAddress(from account: Account) throws -> String {
        addressForAccount(account)
    }
}

struct ChainClientTests {
    @Test func deriveAddressReceivesTheProvidedAccount() async throws {
        let wallet = Wallet.create()
        let account = try await wallet.account(.ethereum)
        let client = MockChainClient(blockchain: .ethereum) { _ in "0xmocked" }
        let address = try client.deriveAddress(from: account)
        #expect(address == "0xmocked")
    }

    @Test func blockchainMatchesTheClientsConfiguredChain() {
        let client = MockChainClient(blockchain: .bitcoin) { _ in "" }
        #expect(client.blockchain == .bitcoin)
    }
}
