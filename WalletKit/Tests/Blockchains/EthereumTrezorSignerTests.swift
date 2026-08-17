// Spec-driven test for EthereumTrezorSigner.
//
// EthereumTrezorSigner's decode (signTx(from:)) and re-encode
// (signedTransaction(_:signature:)) halves are real, Rust-backed operations
// shared with EthereumPKeySigner's software path via EthereumSignerFfi —
// only the device conversation itself is unimplemented (no walletkit-trezor
// transport exists yet). Constructing a signer still requires a connected
// device to read its public key, so this whole suite is device-gated;
// `#require`/`withKnownIssue` skip cleanly when none is available, the way
// the deleted HardwareSignerTests did.
//
// Runs the same ethereum-tx.json vectors as EthereumPKeySignerTests. Since
// there's no real Trezor signing yet, the "device-produced" signature is
// stood in for by computing it straight from the vector's private key via
// the same `EthereumSignerFfi.signature(signingData:privateKey:)` a real
// device conversation would eventually stand in for — everything else
// (decode, re-encode) is exercised for real.

import Foundation
import Testing
@testable import WalletKit
import WalletKitRust

private struct EthereumTxVector: Decodable, Sendable, CustomTestStringConvertible {
    let label: String
    let privateKey: String
    let chainId: UInt64
    let signingDataHex: String
    let signedTxHex: String

    var testDescription: String { label }
}

private func loadVectors() -> [EthereumTxVector] {
    let url = Bundle.module.url(forResource: "ethereum-tx", withExtension: "json")!
    // swiftlint:disable force_try
    let data = try! Data(contentsOf: url)
    return try! JSONDecoder().decode([EthereumTxVector].self, from: data)
    // swiftlint:enable force_try
}

private extension String {
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

struct EthereumTrezorSignerTests {
    fileprivate static let txVectors: [EthereumTxVector] = loadVectors()

    @Test func decodeAndEncodeRoundTripEveryVectorThroughAConnectedDevice() async throws {
        await withKnownIssue("requires a connected hardware wallet, unavailable in CI") {
            let manager = HardwareDeviceManager()
            let devices = try await manager.scan()
            let info = try #require(devices.first, "requires a connected test device")
            let device = try await manager.connect(info, delegate: RecordingHardwareDeviceDelegate())
            let derivationPath = TestAccountFactory.bip44Path(coinType: 60)

            for vector in Self.txVectors {
                let signer = try await EthereumTrezorSigner(
                    chainId: vector.chainId,
                    device: device,
                    derivationPath: derivationPath
                )

                let signTx = try signer.signTx(from: vector.signingDataHex.hexDecoded)
                #expect(signTx.chainId == vector.chainId)

                // Stands in for a real device signature — no walletkit-trezor
                // transport exists yet.
                let privateKey = try PrivateKey(curve: .secp256k1, rawBytes: vector.privateKey.hexDecoded)
                let raw = try EthereumSignerFfi(chainId: vector.chainId).signature(
                    signingData: vector.signingDataHex.hexDecoded,
                    privateKey: privateKey.raw
                )
                let signature = EthereumSignature(v: raw.v, r: raw.r, s: raw.s)

                let signed = try signer.signedTransaction(vector.signingDataHex.hexDecoded, signature: signature)
                #expect(signed.hexEncoded == vector.signedTxHex, "\(vector.label)")
            }
        }
    }

    @Test func signThrowsUntilTheTrezorTransportIsImplemented() async throws {
        await withKnownIssue("requires a connected hardware wallet, unavailable in CI") {
            let manager = HardwareDeviceManager()
            let devices = try await manager.scan()
            let info = try #require(devices.first, "requires a connected test device")
            let device = try await manager.connect(info, delegate: RecordingHardwareDeviceDelegate())
            let signer = try await EthereumTrezorSigner(
                device: device,
                derivationPath: TestAccountFactory.bip44Path(coinType: 60)
            )

            await #expect(throws: WalletKitError.self) {
                _ = try await signer.sign(transaction: Self.txVectors[0].signingDataHex.hexDecoded)
            }
        }
    }
}
