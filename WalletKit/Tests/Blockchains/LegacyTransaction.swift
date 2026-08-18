// Test-only RLP encoder + unsigned legacy-transaction builder, backing
// EthereumAnvilTests.swift. Deliberately not in Sources/: EthereumRPCClient's
// own doc comment says "this client builds no transactions of its own", and
// EthereumPKeySigner.sign(transaction:) takes already-RLP-encoded EIP-155
// signing data rather than building it — there is no transaction builder
// anywhere in WalletKit today, on either side of the FFI boundary.
//
// Cross-checked against the existing WalletKit/TestVectors/ethereum-tx.json
// vectors in LegacyTransactionTests.swift before ever being trusted against
// a live Anvil node.

import BigInt
import Foundation
import WalletKit

/// A minimal Ethereum RLP encoder — byte-strings and lists only (no nested
/// lists are needed for a legacy transaction's flat 9-field structure).
enum RLP {
    /// Encodes a single byte-string item.
    static func encode(_ bytes: Data) -> Data {
        if bytes.count == 1, let byte = bytes.first, byte < 0x80 {
            return bytes
        }
        return encodeHeader(base: 0x80, longBase: 0xB7, count: bytes.count) + bytes
    }

    /// Encodes a list whose `items` are already individually RLP-encoded.
    static func encodeList(_ items: [Data]) -> Data {
        let payload = items.reduce(Data(), +)
        return encodeHeader(base: 0xC0, longBase: 0xF7, count: payload.count) + payload
    }

    private static func encodeHeader(base: UInt8, longBase: UInt8, count: Int) -> Data {
        if count <= 55 {
            return Data([base + UInt8(count)])
        }

        var lengthBytes = Data()
        var remaining = count
        while remaining > 0 {
            lengthBytes.insert(UInt8(remaining & 0xFF), at: 0)
            remaining >>= 8
        }
        return Data([longBase + UInt8(lengthBytes.count)]) + lengthBytes
    }
}

/// The 9-field EIP-155 legacy transaction — everything
/// `EthereumPKeySigner.sign(transaction:)` needs as its already-RLP-encoded
/// `signingData` input.
struct UnsignedLegacyTransaction {
    let nonce: BigUInt
    let gasPrice: BigUInt
    let gasLimit: BigUInt
    let to: EthereumAddress?
    let value: BigUInt
    let data: Data
    let chainId: UInt64

    /// `RLP([nonce, gasPrice, gasLimit, to, value, data, chainId, 0, 0])` —
    /// exactly what `EthereumPKeySigner.sign(transaction:)` expects.
    var signingData: Data {
        RLP.encodeList([
            RLP.encode(nonce.serialize()),
            RLP.encode(gasPrice.serialize()),
            RLP.encode(gasLimit.serialize()),
            RLP.encode(to?.rawBytes ?? Data()),
            RLP.encode(value.serialize()),
            RLP.encode(data),
            RLP.encode(BigUInt(chainId).serialize()),
            RLP.encode(Data()),
            RLP.encode(Data())
        ])
    }
}
