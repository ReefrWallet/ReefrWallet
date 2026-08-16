// Spec-driven test for Docs/Design Specification/Clients/Signer.swift.
//
// Ethereum's real conformer is covered separately by EthereumSignerTests
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
        guard let string = String(bytes: rawBytes, encoding: .utf8)  else {
            throw WalletKitError.invalidAddress(reason: "Invalid bytes")
        }

        self.string = string
    }

    var rawBytes: Data { Data(string.utf8) }
}

private struct MockSigner: Signer {
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

struct SignerTests {
    @Test func addressReceivesTheProvidedAccount() async throws {
        let account = try TestAccountFactory.ethereumAccount()
        let signer = MockSigner(
            blockchain: .ethereum(1),
            addressForAccount: { _ in "0xmocked" },
            signHandler: { data, _ in data }
        )
        let address = try signer.address(for: account)
        #expect(address.string == "0xmocked")
    }

    @Test func blockchainMatchesTheSignersConfiguredChain() {
        let signer = MockSigner(blockchain: .bitcoin, addressForAccount: { _ in "" }, signHandler: { data, _ in data })
        #expect(signer.blockchain == .bitcoin)
    }

    @Test func signForwardsTheTransactionAndAccount() async throws {
        let account = try TestAccountFactory.ethereumAccount()
        var receivedAccount: Account?
        let signer = MockSigner(
            blockchain: .ethereum(1),
            addressForAccount: { _ in "" },
            signHandler: { data, acct in
                receivedAccount = acct
                return data
            }
        )

        let transaction = Data([0x01, 0x02, 0x03])
        let signed = try await signer.sign(transaction: transaction, account: account)
        #expect(signed == transaction)
        #expect(receivedAccount === account)
    }
}
