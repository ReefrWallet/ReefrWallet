// Test-only BCS encoder + unsigned `TransactionData` builder, backing
// SuiLocalnetTests.swift. Deliberately not in Sources/: SuiGRPCClient's own
// doc comment says it "builds no transactions of its own", and
// SuiPKeySigner.sign(transaction:) takes already-BCS-encoded
// `TransactionData` bytes rather than building them — there is no
// transaction builder anywhere in WalletKit today, on either side of the
// FFI boundary.
//
// Only models the one PTB shape this suite needs: split the gas coin into
// N pieces and transfer each to a different recipient — the same shape as
// TestVectors/sui-tx.json's `ed25519-split-and-transfer-sui` (single
// transfer) and `secp256k1-split-two-and-transfer-to-two-recipients` (two
// transfers) vectors. The exact byte layout below — inputs ordered as all
// amounts followed by all recipients, a single `SplitCoins` command
// followed by one `TransferObjects` per transfer, `Result(0)` for a lone
// transfer vs. `NestedResult(0, i)` once there's more than one — was
// reverse-engineered by decoding those two vectors' `transactionDataBcsHex`
// byte-for-byte; SuiTransactionDataTests.swift cross-checks the encoder
// against both before it's ever trusted against a live node.

import Foundation
import WalletKit

/// A minimal BCS (Binary Canonical Serialization) encoder — just the
/// primitives a `TransactionDataV1` needs: ULEB128 lengths, little-endian
/// fixed-width integers, and length-prefixed byte vectors.
enum BCS {
    /// Encodes `value` as ULEB128 — how BCS encodes `Vec<T>` lengths and
    /// enum variant tags.
    static func uleb128(_ value: Int) -> Data {
        var remaining = UInt(value)
        var out = Data()
        repeat {
            var byte = UInt8(remaining & 0x7F)
            remaining >>= 7
            if remaining != 0 {
                byte |= 0x80
            }
            out.append(byte)
        } while remaining != 0
        return out
    }

    /// Encodes `value` as 8 little-endian bytes.
    static func u64(_ value: UInt64) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    /// Encodes `value` as 2 little-endian bytes — how BCS encodes an
    /// `Argument::Input`/`Result`/`NestedResult` index.
    static func u16(_ value: UInt16) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    /// Encodes `bytes` as a length-prefixed byte vector: a ULEB128 length
    /// followed by the raw bytes — how BCS encodes `Vec<u8>`, e.g. a
    /// `CallArg::Pure` payload or an `ObjectDigest`.
    static func byteVector(_ bytes: Data) -> Data {
        uleb128(bytes.count) + bytes
    }
}

/// A `(object_id, version, digest)` triple identifying a specific version
/// of an on-chain object — what a transaction's gas payment (and any other
/// object input) references.
struct SuiObjectReference {
    let objectId: Data
    let version: UInt64
    let digest: Data
}

/// An unsigned "split the gas coin and transfer the pieces" Programmable
/// Transaction Block — the canonical wallet-transfer PTB, and the only
/// shape this builder models. Produces the raw BCS `TransactionData` bytes
/// `SuiPKeySigner.sign(transaction:)` expects.
struct UnsignedSuiTransaction {
    let sender: SuiAddress
    let transfers: [(recipient: SuiAddress, amount: UInt64)]
    let gasPayment: [SuiObjectReference]
    let gasOwner: SuiAddress
    let gasPrice: UInt64
    let gasBudget: UInt64

    /// BCS-encoded `TransactionData::V1(TransactionDataV1 { kind, sender,
    /// gas_data, expiration: None })`, where `kind` is a
    /// `ProgrammableTransaction` with:
    ///   - inputs: one `CallArg::Pure(u64)` per transfer amount, then one
    ///     `CallArg::Pure(address)` per recipient.
    ///   - commands: `SplitCoins(GasCoin, [Input(0), Input(1), …])`,
    ///     followed by one `TransferObjects([piece], Input(recipient))`
    ///     per transfer — `piece` is `Result(0)` when there's exactly one
    ///     transfer, or `NestedResult(0, i)` once `SplitCoins` produces
    ///     more than one coin.
    var transactionDataBcs: Data {
        var data = Data()
        data.append(0x00) // TransactionData::V1
        data.append(0x00) // TransactionKind::ProgrammableTransaction

        let amountInputs = transfers.map { BCS.byteVector(BCS.u64($0.amount)) }
        let recipientInputs = transfers.map { BCS.byteVector($0.recipient.rawBytes) }
        let inputs = amountInputs + recipientInputs
        data.append(BCS.uleb128(inputs.count))
        for input in inputs {
            data.append(0x00) // CallArg::Pure
            data.append(input)
        }

        data.append(BCS.uleb128(1 + transfers.count)) // SplitCoins + one TransferObjects per transfer

        data.append(0x02) // Command::SplitCoins
        data.append(0x00) // Argument::GasCoin
        data.append(BCS.uleb128(transfers.count))
        for index in 0..<transfers.count {
            data.append(0x01) // Argument::Input
            data.append(BCS.u16(UInt16(index)))
        }

        for index in transfers.indices {
            data.append(0x01) // Command::TransferObjects
            data.append(BCS.uleb128(1))
            if transfers.count == 1 {
                data.append(0x02) // Argument::Result
                data.append(BCS.u16(0))
            } else {
                data.append(0x03) // Argument::NestedResult
                data.append(BCS.u16(0))
                data.append(BCS.u16(UInt16(index)))
            }
            data.append(0x01) // Argument::Input, the matching recipient
            data.append(BCS.u16(UInt16(transfers.count + index)))
        }

        data.append(sender.rawBytes)

        data.append(BCS.uleb128(gasPayment.count))
        for reference in gasPayment {
            data.append(reference.objectId)
            data.append(BCS.u64(reference.version))
            data.append(BCS.byteVector(reference.digest))
        }
        data.append(gasOwner.rawBytes)
        data.append(BCS.u64(gasPrice))
        data.append(BCS.u64(gasBudget))

        data.append(0x00) // TransactionExpiration::None

        return data
    }
}
