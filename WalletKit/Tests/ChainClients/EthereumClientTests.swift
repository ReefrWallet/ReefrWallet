// Spec-driven test for Docs/Design Specification/Clients/EthereumClient.swift.
// See "Testing strategy" in Docs/Overview.md.
//
// Runs the same two shared vector files as the Rust side
// (Rust/walletkit-ffi/src/blockchain_clients/{ethereum_address,ethereum_client}.rs)
// through the exported `EthereumClient`, so both sides of the FFI boundary
// are checked against identical expected output.
//
// The vectors are keyed by raw private keys, not mnemonics/derivation
// paths, so tests import them via `PrivateKey(curve:rawBytes:)` and sign
// via `EthereumClient.sign(transaction:privateKey:)` rather than going
// through an `Account` — `sign(transaction:account:)` isn't wired up to a
// signing key yet (see EthereumClient's doc comment in Sources).

import Foundation
import Testing
@testable import WalletKit

private struct EthereumAddressVector: Decodable, Sendable, CustomTestStringConvertible {
    let label: String
    let privateKey: String
    let address: String

    var testDescription: String { label }
}

private struct EthereumTxVector: Decodable, Sendable, CustomTestStringConvertible {
    let label: String
    let privateKey: String
    let signingDataHex: String
    let signingHashHex: String
    let address: String
    let signedTxHex: String

    var testDescription: String { label }
}

private func loadVectors<T: Decodable>(_ resource: String) -> [T] {
    let url = Bundle.module.url(forResource: resource, withExtension: "json")!
    let data = try! Data(contentsOf: url)
    return try! JSONDecoder().decode([T].self, from: data)
}

private extension String {
    /// Decodes a `0x`-prefixed (or bare) hex string, as used throughout the
    /// Ethereum test vector files.
    var hexDecoded: Data {
        let hex = hasPrefix("0x") ? String(dropFirst(2)) : self
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            data.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return data
    }
}

private extension Data {
    var hexEncoded: String {
        "0x" + map { String(format: "%02x", $0) }.joined()
    }
}

struct EthereumClientTests {
    fileprivate static let addressVectors: [EthereumAddressVector] = loadVectors("ethereum-address")
    fileprivate static let txVectors: [EthereumTxVector] = loadVectors("ethereum-tx")

    @Test(arguments: addressVectors)
    fileprivate func addressMatchesTheVectorsExpectedChecksummedAddress(vector: EthereumAddressVector) throws {
        let privateKey = try PrivateKey(curve: .secp256k1, rawBytes: vector.privateKey.hexDecoded)
        let address = try EthereumClient().address(for: privateKey.publicKey)
        #expect(address.checksummed == vector.address)
        #expect(address.string == vector.address)
    }

    @Test(arguments: addressVectors)
    fileprivate func addressAcceptsTheAccountBasedOverloadToo(vector: EthereumAddressVector) async throws {
        // `EthereumClient.address(for: Account)` is a thin wrapper around
        // `address(for: PublicKey)` — exercised here via a freshly created
        // wallet's account rather than the vector's key (the vector's raw
        // key has no derivation path to attach to an Account), just to
        // confirm the Account-based overload itself works end to end.
        let wallet = Wallet.create()
        let account = try await wallet.account(.ethereum)
        let viaAccount = try EthereumClient().address(for: account)
        let viaPublicKey = try EthereumClient().address(for: account.publicKey)
        #expect(viaAccount == viaPublicKey)
    }

    @Test(arguments: txVectors)
    fileprivate func signProducesTheVectorsExpectedSignedTransaction(vector: EthereumTxVector) async throws {
        let privateKey = try PrivateKey(curve: .secp256k1, rawBytes: vector.privateKey.hexDecoded)
        let client = EthereumClient()

        // Sanity check: the vector's signing key also derives the vector's
        // own address, cross-checking this test's private-key import
        // against EthereumAddressTests'/the address vectors' coverage.
        let address = try client.address(for: privateKey.publicKey)
        #expect(address.checksummed == vector.address)

        let signed = try await client.sign(transaction: vector.signingDataHex.hexDecoded, privateKey: privateKey)
        #expect(signed.hexEncoded == vector.signedTxHex)
    }

    @Test func signThroughAccountThrowsUntilAccountCanSupplyASigningKey() async throws {
        let wallet = Wallet.create()
        let account = try await wallet.account(.ethereum)
        await #expect(throws: WalletKitError.self) {
            _ = try await EthereumClient().sign(transaction: Data([0xc0]), account: account)
        }
    }
}
