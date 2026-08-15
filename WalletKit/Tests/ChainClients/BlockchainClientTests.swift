// Spec-driven test for Docs/Design Specification/Clients/BlockchainClient.swift.
//
// Ethereum's real conformer is covered separately by EthereumClientTests
// and EthereumAddressTests; this exercises the protocol's shape itself
// through a local mock, independent of any one chain.

import Foundation
import Testing
@testable import WalletKit

private struct MockAddress: BlockchainAddress {
    let string: String

    init(string: String) throws {
        self.string = string
    }

    init(rawBytes: Data) throws {
        string = String(decoding: rawBytes, as: UTF8.self)
    }

    var rawBytes: Data { Data(string.utf8) }
}

private struct MockBlockchainClient: BlockchainClient {
    typealias Address = MockAddress

    let blockchain: Blockchain
    let addressForAccount: (Account) -> String
    let signHandler: (Data, Account) async throws -> Data

    func address(for account: Account) throws -> MockAddress {
        try MockAddress(string: addressForAccount(account))
    }

    func sign(transaction: Data, account: Account) async throws -> Data {
        try await signHandler(transaction, account)
    }
}

struct BlockchainClientTests {
    @Test func addressReceivesTheProvidedAccount() async throws {
        let wallet = Wallet.create()
        let account = try await wallet.account(.ethereum)
        let client = MockBlockchainClient(blockchain: .ethereum, addressForAccount: { _ in "0xmocked" }, signHandler: { data, _ in data })
        let address = try client.address(for: account)
        #expect(address.string == "0xmocked")
    }

    @Test func blockchainMatchesTheClientsConfiguredChain() {
        let client = MockBlockchainClient(blockchain: .bitcoin, addressForAccount: { _ in "" }, signHandler: { data, _ in data })
        #expect(client.blockchain == .bitcoin)
    }

    @Test func signForwardsTheTransactionAndAccount() async throws {
        let wallet = Wallet.create()
        let account = try await wallet.account(.ethereum)
        var receivedAccount: Account?
        let client = MockBlockchainClient(
            blockchain: .ethereum,
            addressForAccount: { _ in "" },
            signHandler: { data, acct in
                receivedAccount = acct
                return data
            }
        )

        let transaction = Data([0x01, 0x02, 0x03])
        let signed = try await client.sign(transaction: transaction, account: account)
        #expect(signed == transaction)
        #expect(receivedAccount === account)
    }
}
