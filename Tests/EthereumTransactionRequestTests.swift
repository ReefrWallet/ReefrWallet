// Unit tests for EthereumTransactionRequest's strict field parsing:
// absent → default, valid → used, present-but-malformed → invalidParams.

import BigInt
import Foundation
import Testing
@testable import ReefrWallet

private let from = "0x00000000000000000000000000000000000000aa"
private let to = "0x00000000000000000000000000000000000000bb"

private func request(_ fields: [String: JSONValue]) throws(DappError) -> EthereumTransactionRequest {
    try EthereumTransactionRequest(.object(["from": .string(from)].merging(fields) { _, new in new }))
}

private func isInvalidParams(_ fields: [String: JSONValue]) -> Bool {
    do {
        _ = try request(fields)
        return false
    } catch {
        guard case .invalidParams = error else {
            return false
        }

        return true
    }
}

@Suite
struct EthereumTransactionRequestTests {
    @Test
    func absentFieldsTakeTheirDefaults() throws {
        let parsed = try request(["to": .string(to)])

        #expect(parsed.value == 0)
        #expect(parsed.data.isEmpty)
        #expect(parsed.gasLimit == nil)
        #expect(parsed.gasPrice == nil)
        #expect(parsed.maxFeePerGas == nil)
        #expect(parsed.maxPriorityFeePerGas == nil)
        #expect(parsed.hasFeeOverrides == false)
    }

    @Test
    func nullFieldsAreTreatedAsAbsent() throws {
        let parsed = try request(["to": .null, "value": .null, "data": .null, "gas": .null])

        #expect(parsed.to == nil)
        #expect(parsed.value == 0)
        #expect(parsed.data.isEmpty)
        #expect(parsed.gasLimit == nil)
    }

    @Test
    func validFieldsAreUsed() throws {
        let parsed = try request([
            "to": .string(to),
            "value": .string("0x0de0b6b3a7640000"),
            "data": .string("0xa9059cbb"),
            "gas": .string("0x5208"),
            "maxFeePerGas": .string("0x2"),
            "maxPriorityFeePerGas": .string("0x1")
        ])

        #expect(parsed.toString == to)
        #expect(parsed.value == BigUInt(1_000_000_000_000_000_000))
        #expect(parsed.data == Data([0xa9, 0x05, 0x9c, 0xbb]))
        #expect(parsed.gasLimit == 21_000)
        #expect(parsed.maxFeePerGas == 2)
        #expect(parsed.maxPriorityFeePerGas == 1)
        #expect(parsed.hasFeeOverrides)
    }

    @Test
    func inputIsAcceptedInPlaceOfData() throws {
        #expect(try request(["input": .string("0x01")]).data == Data([0x01]))
        #expect(try request(["data": .string("0x01"), "input": .string("0x01")]).data == Data([0x01]))
        #expect(isInvalidParams(["data": .string("0x01"), "input": .string("0x02")]))
    }

    @Test(arguments: ["value", "gas", "gasPrice", "maxFeePerGas", "maxPriorityFeePerGas"])
    func malformedQuantitiesAreRejected(key: String) {
        let malformed: [JSONValue] = [
            .string("not-hex"), .string("0x"), .string("12"), .string("0x+1"), .string("0xg"), .number(1)
        ]

        for bad in malformed {
            #expect(isInvalidParams([key: bad]), "\(key): \(bad)")
        }

        #expect(isInvalidParams([key: .string("0x1" + String(repeating: "0", count: 64))]), "\(key): > uint256")
    }

    @Test
    func malformedDataIsRejected() {
        for bad: JSONValue in [.string("0xabc"), .string("abcd"), .string("0xzz"), .string("0x+f"), .number(0)] {
            #expect(isInvalidParams(["data": bad]), "\(bad)")
        }

        #expect(isInvalidParams(["input": .string("0xabc")]))
    }

    @Test
    func malformedToIsRejected() {
        #expect(isInvalidParams(["to": .string("0x1234")]))
        #expect(isInvalidParams(["to": .number(1)]))
    }

    @Test
    func inconsistentFeeFieldsAreRejected() {
        #expect(isInvalidParams(["gasPrice": .string("0x1"), "maxFeePerGas": .string("0x1")]))
        #expect(isInvalidParams(["gasPrice": .string("0x1"), "maxPriorityFeePerGas": .string("0x1")]))
        #expect(isInvalidParams(["maxFeePerGas": .string("0x1"), "maxPriorityFeePerGas": .string("0x2")]))
        #expect(isInvalidParams(["gas": .string("0x5207")]))
    }

    @Test
    func missingOrNonObjectTransactionIsRejected() {
        #expect(throws: DappError.self) { try EthereumTransactionRequest(.object([:])) }
        #expect(throws: DappError.self) { try EthereumTransactionRequest(.string(from)) }
    }
}
