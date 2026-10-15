// Tests for providers/sui.js's transaction building: the bundled
// `@mysten/sui` `Transaction.build()` (vendor/sui-sdk.js) over sui.js's
// native-lookup adapter. The vectors are the real SDK's own output for these
// scenarios (TestVectors/sui-dapp-transactions.json, ADR-023); the rest cover
// gas resolution and the rejections sui.js makes before native would.

import Foundation
import JavaScriptCore
import Testing
@testable import ReefrWallet

struct SuiTransactionBuilderScriptTests {
    private static let sender = "0x" + String(repeating: "11", count: 32)

    private func makeHarness() throws -> DappWalletStandardJSHarness {
        try DappWalletStandardJSHarness(providerResourceNames: ["vendor/sui-sdk.js", "providers/sui.js"])
    }

    /// Signs `transactionJSON` through `sui:signTransaction`, answering
    /// lookups from `nativeResponses`, and returns the `transactionBytes`
    /// native was asked to sign.
    private func build(
        _ harness: DappWalletStandardJSHarness,
        transactionJSON: String,
        sender: String = Self.sender,
        nativeResponses: [String: JSONValue] = [:]
    ) throws -> String? {
        var transactionBytes: String?

        harness.handleRequest = { namespace, method, params in
            #expect(namespace == "sui")

            if method == "signTransaction" {
                transactionBytes = params["transactionBytes"]?.stringValue
                return .success(.object(["bytes": .string(transactionBytes ?? ""), "signature": .string("c2ln")]))
            }

            guard let response = nativeResponses[method] else {
                Issue.record("unexpected native call: \(method)")
                return .failure(.object(["message": .string("unexpected call")]))
            }

            return .success(response)
        }

        // swiftlint:disable all
        try harness.run("""
        window.__testInput = {
            transaction: { toJSON: function () { return Promise.resolve(\(try jsString(transactionJSON))); } },
            account: { address: \(try jsString(sender)) },
            chain: 'sui:testnet',
        };
        """)
        // swiftlint:enable all

        try harness.invoke("__capturedWallet.features['sui:signTransaction'].signTransaction(window.__testInput)")
        return transactionBytes
    }

    private func jsString(_ value: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        return String(data: data, encoding: .utf8) ?? "\"\""
    }

    private func minimalJSON(
        sender: String = Self.sender, expiration: String = "null", gasOwner: String = "null"
    ) -> String {
        """
        {"version":2,"sender":"\(sender)","expiration":\(expiration),
         "gasData":{"budget":"1","price":"1","owner":\(gasOwner),"payment":[]},
         "inputs":[],"commands":[{"MakeMoveVec":{"type":null,"elements":[]}}]}
        """
    }

    @Test(arguments: TransactionVectorFile.load().vectors)
    func buildMatchesRealSdkOutput(vector: TransactionVector) throws {
        let harness = try makeHarness()
        let bytes = try build(
            harness,
            transactionJSON: vector.transactionJSON,
            sender: vector.sender,
            nativeResponses: vector.nativeResponses
        )
        #expect(bytes == vector.expectedBytesBase64)
    }

    /// No gas price, budget or payment: the reference gas price, one
    /// simulation (`computation + 1000·price + storage − rebate`) and the
    /// sender's coins fill them in, with `expiration: None`.
    @Test
    func resolvesGasThroughNativeLookups() throws {
        let vector = TransactionVectorFile.load().vectors.first { $0.name == "movecall-shared-object-unresolved-pure" }!
        let json = vector.transactionJSON.replacingOccurrences(
            of: #""gasData":\{.*?\]\}"#,
            with: #""gasData":{"budget":null,"price":null,"owner":null,"payment":null}"#,
            options: .regularExpression
        )

        var responses = vector.nativeResponses
        responses["getReferenceGasPrice"] = .object(["price": .string("1000")])
        responses["simulateTransaction"] = .object([
            "computationCost": .string("1000000"), "storageCost": .string("2000000"), "storageRebate": .string("500000")
        ])
        responses["getCoins"] = .object([
            "coins": .array([
                .object([
                    "objectId": .string("0x" + String(repeating: "44", count: 32)),
                    "version": .string("1"),
                    "digest": .string("ERERERERERERERERERERERERERERERERERERERERERE="),
                    "balance": .string("9000000000")
                ])
            ])
        ])

        let harness = try makeHarness()
        let bytes = try build(harness, transactionJSON: json, nativeResponses: responses)

        // The vector's own bytes, with the simulated 3_500_000 budget.
        let expected = vector.expectedBytesBase64.replacingOccurrences(of: "EBLTAAAAAAAAA==", with: "OBnNQAAAAAAAA==")
        #expect(bytes == expected)
        #expect(harness.recordedRequests.map(\.method).contains("simulateTransaction"))
    }

    @Test
    func rejectsNonNoneExpiration() throws {
        let harness = try makeHarness()
        #expect(throws: DappWalletStandardJSHarnessError.self) {
            try build(harness, transactionJSON: minimalJSON(expiration: #"{"Epoch":"10"}"#))
        }
    }

    @Test
    func rejectsForeignSender() throws {
        let harness = try makeHarness()
        #expect(throws: DappWalletStandardJSHarnessError.self) {
            try build(harness, transactionJSON: minimalJSON(sender: "0x" + String(repeating: "22", count: 32)))
        }
    }

    @Test
    func rejectsSponsoredTransactions() throws {
        let harness = try makeHarness()
        let sponsor = "\"0x" + String(repeating: "33", count: 32) + "\""
        #expect(throws: DappWalletStandardJSHarnessError.self) {
            try build(harness, transactionJSON: minimalJSON(gasOwner: sponsor))
        }
    }

    @Test
    func rejectsUnsupportedPureDatatype() throws {
        let harness = try makeHarness()
        let json = """
        {"version":2,"sender":"\(Self.sender)","expiration":null,
         "gasData":{"budget":"1","price":"1","owner":null,"payment":[]},
         "inputs":[{"UnresolvedPure":{"value":1}}],
         "commands":[{"MoveCall":{
           "package":"0x99","module":"m","function":"f","typeArguments":[],"arguments":[{"Input":0}]
         }}]}
        """
        let unsupportedType = JSONValue.object([
            "kind": .string("datatype"), "typeName": .string("0x99::m::NotPureEncodable"), "typeParameters": .array([])
        ])
        let responses: [String: JSONValue] = [
            "getMoveFunction": .object([
                "parameters": .array([.object(["reference": .string("none"), "type": unsupportedType])])
            ])
        ]
        #expect(throws: DappWalletStandardJSHarnessError.self) {
            try build(harness, transactionJSON: json, nativeResponses: responses)
        }
    }

    @Test
    func rejectsUnsupportedObjectOwnerKind() throws {
        let harness = try makeHarness()
        let json = """
        {"version":2,"sender":"\(Self.sender)","expiration":null,
         "gasData":{"budget":"1","price":"1","owner":null,"payment":[]},
         "inputs":[{"UnresolvedObject":{"objectId":"0x55"}}],
         "commands":[{"TransferObjects":{"objects":[{"Input":0}],"address":{"Input":0}}}]}
        """
        let responses: [String: JSONValue] = [
            "getObjects": .object([
                "objects": .array([
                    .object([
                        "objectId": .string("0x0000000000000000000000000000000000000000000000000000000000000055"),
                        "version": .string("1"),
                        "digest": .string("ERERERERERERERERERERERERERERERERERERERERERE="),
                        "owner": .object(["kind": .string("unsupported")])
                    ])
                ])
            ])
        ]
        #expect(throws: DappWalletStandardJSHarnessError.self) {
            try build(harness, transactionJSON: json, nativeResponses: responses)
        }
    }
}

/// `TestVectors/sui-dapp-transactions.json` — see that file's own
/// `_comment` for how each vector's `expectedBytesBase64` was produced.
struct TransactionVector: Decodable, Sendable, CustomTestStringConvertible {
    let name: String
    let description: String
    let sender: String
    let transactionJSON: String
    let nativeResponses: [String: JSONValue]
    let expectedBytesBase64: String

    var testDescription: String { name }
}

struct TransactionVectorFile: Decodable {
    let vectors: [TransactionVector]

    static func load() -> Self {
        let url = Bundle.module.url(forResource: "sui-dapp-transactions", withExtension: "json")!
        let data = try! Data(contentsOf: url) // swiftlint:disable:this force_try
        return try! JSONDecoder().decode(Self.self, from: data) // swiftlint:disable:this force_try
    }
}
