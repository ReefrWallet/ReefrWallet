// Spec-driven test for Docs/Design Specification/Clients/Sui/SuiSigner.swift.
// See "Testing strategy" in Docs/Overview.md.
//
// Runs the same two shared vector files as the Rust side
// (Rust/walletkit-ffi/src/blockchain_clients/{sui_address,sui_signer}.rs)
// through the exported `SuiSigner`, so both sides of the FFI boundary are
// checked against identical expected output.
//
// sui-address.json was generated with the official `sui keytool generate
// <scheme> --json` (Sui CLI 1.66.2) — see that file for how each entry's
// `privateKey` was recovered from the tool's own keypair file.
// sui-tx.json was generated from real Programmable Transaction Blocks
// built with `sui client ptb ... --serialize-unsigned-transaction`
// against a local `sui start` test validator, signed with `sui keytool
// sign`, and independently confirmed with both `sui keytool
// decode-or-verify-tx` and `sui client execute-signed-tx` — see that file
// for the full provenance note per vector.
//
// secp256r1 vectors are present in both files but skipped here: `Curve`
// has no case for that scheme (see `common::Curve` on the Rust side), so
// there's no `PrivateKey`/`SuiSigner` to drive through — the Rust tests
// cover that scheme's address/signing formulas directly instead.
//
// The tx vectors are keyed by raw private keys, not mnemonics/derivation
// paths, so tests import them via `PrivateKey(curve:rawBytes:)` and sign
// via `SuiSigner.sign(transaction:privateKey:)` rather than going through
// an `Account` — `sign(transaction:account:)` isn't wired up to a signing
// key yet (see SuiSigner's doc comment in Sources).

import Foundation
import Testing
@testable import WalletKit

private struct SuiAddressVector: Decodable, Sendable, CustomTestStringConvertible {
    let label: String
    let scheme: String
    let privateKey: String
    let publicKey: String
    let address: String

    var testDescription: String { label }

    var curve: Curve? {
        switch scheme {
        case "ed25519": return .ed25519
        case "secp256k1": return .secp256k1
        default: return nil
        }
    }
}

private struct SuiTxVector: Decodable, Sendable, CustomTestStringConvertible {
    let label: String
    let scheme: String
    let privateKey: String
    let transactionDataBcsHex: String
    let signatureHex: String

    var testDescription: String { label }

    var curve: Curve? {
        switch scheme {
        case "ed25519": return .ed25519
        case "secp256k1": return .secp256k1
        default: return nil
        }
    }
}

private func loadVectors<T: Decodable>(_ resource: String) -> [T] {
    // swiftlint:disable force_try
    let url = Bundle.module.url(forResource: resource, withExtension: "json")!
    let data = try! Data(contentsOf: url)
    return try! JSONDecoder().decode([T].self, from: data)
    // swiftlint:enable force_try
}

private extension String {
    /// Decodes a `0x`-prefixed (or bare) hex string, as used throughout the
    /// Sui test vector files.
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

struct SuiSignerTests {
    fileprivate static let vectors: [SuiAddressVector] = loadVectors("sui-address")
    fileprivate static let supportedVectors = vectors.filter { $0.curve != nil }
    fileprivate static let txVectors: [SuiTxVector] = loadVectors("sui-tx")
    fileprivate static let supportedTxVectors = txVectors.filter { $0.curve != nil }

    @Test(arguments: supportedVectors)
    fileprivate func addressMatchesTheVectorsExpectedAddress(vector: SuiAddressVector) throws {
        let curve = try #require(vector.curve)
        let privateKey = try PrivateKey(curve: curve, rawBytes: vector.privateKey.hexDecoded)

        // Sanity check: the vector's private key derives the vector's own
        // public key, cross-checking this test's key import.
        #expect(privateKey.publicKey.rawBytes == vector.publicKey.hexDecoded)

        let address = try SuiSigner(curve: curve).address(for: privateKey.publicKey)
        #expect(address.string == vector.address)
    }

    @Test(arguments: supportedVectors)
    fileprivate func addressAcceptsTheAccountBasedOverloadToo(vector: SuiAddressVector) async throws {
        let curve = try #require(vector.curve)
        // `SuiSigner.address(for: Account)` is a thin wrapper around
        // `address(for: PublicKey)` — exercised here via a freshly derived
        // test account rather than the vector's key (the vector's raw key
        // has no derivation path to attach to an Account), just to confirm
        // the Account-based overload itself works end to end.
        let account = try TestAccountFactory.suiAccount(curve: curve)
        let viaAccount = try SuiSigner(curve: curve).address(for: account)
        let viaPublicKey = try SuiSigner(curve: curve).address(for: account.publicKey)
        #expect(viaAccount == viaPublicKey)
    }

    @Test func curveDefaultsToEd25519() {
        #expect(SuiSigner().curve == .ed25519)
        #expect(SuiSigner().blockchain == .sui(.ed25519))
    }

    @Test func blockchainReflectsTheConfiguredCurve() {
        #expect(SuiSigner(curve: .secp256k1).blockchain == .sui(.secp256k1))
    }

    @Test func addressRejectsACurveMismatch() throws {
        let ed25519Key = try PrivateKey(curve: .ed25519, rawBytes: Data(repeating: 7, count: 32))
        #expect(throws: WalletKitError.self) {
            _ = try SuiSigner(curve: .secp256k1).address(for: ed25519Key.publicKey)
        }
    }

    @Test(arguments: supportedTxVectors)
    fileprivate func signProducesTheVectorsExpectedSignature(vector: SuiTxVector) async throws {
        let curve = try #require(vector.curve)
        let privateKey = try PrivateKey(curve: curve, rawBytes: vector.privateKey.hexDecoded)
        let signer = SuiSigner(curve: curve)

        let signature = try await signer.sign(
            transaction: vector.transactionDataBcsHex.hexDecoded,
            privateKey: privateKey
        )
        #expect(signature.hexEncoded == vector.signatureHex)
    }

    @Test func signRejectsACurveMismatch() async throws {
        let vector = try #require(Self.supportedTxVectors.first { $0.curve == .ed25519 })
        let privateKey = try PrivateKey(curve: .ed25519, rawBytes: vector.privateKey.hexDecoded)
        let signer = SuiSigner(curve: .secp256k1)
        await #expect(throws: WalletKitError.self) {
            _ = try await signer.sign(transaction: vector.transactionDataBcsHex.hexDecoded, privateKey: privateKey)
        }
    }

    @Test func signThroughAccountThrowsUntilAccountCanSupplyASigningKey() async throws {
        let account = try TestAccountFactory.suiAccount()
        await #expect(throws: WalletKitError.self) {
            _ = try await SuiSigner().sign(transaction: Data([0x00]), account: account)
        }
    }
}
