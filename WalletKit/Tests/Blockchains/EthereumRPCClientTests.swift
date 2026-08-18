// Tests for Sources/Static/Blockchains/Ethereum/EthereumRPCClient.swift —
// the JSON-RPC method names/params each API sends, and the response
// decoding (including its `BlockchainClientError` failure modes). Uses
// StubURLProtocol so these exercise the real `URLSession`/`JSONRPCClient`
// pipeline without a real network call.

import BigInt
import Foundation
import Testing
@testable import WalletKit

// swiftlint:disable force_try
private let someAddress = try! EthereumAddress(rawBytes: Data(repeating: 0xAB, count: 20))
private let someOtherAddress = try! EthereumAddress(rawBytes: Data(repeating: 0xCD, count: 20))
// swiftlint:enable force_try

/// Left-pads `data` to one 32-byte ABI word.
private func word(_ data: Data) -> Data {
    Data(repeating: 0, count: 32 - data.count) + data
}

/// A 32-byte ABI word encoding `value` as an unsigned big-endian integer.
private func word(_ value: BigUInt) -> Data {
    word(value.serialize())
}

/// A 32-byte ABI word encoding `value` as a two's-complement signed integer
/// — computed independently of `EthereumABI.decodeInt256`, the same
/// "verify against an independent computation" principle the Sui address
/// tests use.
private func word(_ value: BigInt) -> Data {
    guard value.sign == .minus else { return word(value.magnitude) }
    return word((BigUInt(1) << 256) - value.magnitude)
}

/// A stub session that returns `result` as a successful JSON-RPC response.
private func stubbedResult(_ result: String) -> StubURLProtocol.Session {
    StubURLProtocol.makeSession(response: .success(body: Data(#"{"jsonrpc":"2.0","id":1,"result":"\#(result)"}"#.utf8)))
}

struct EthereumRPCClientTests {
    private func makeClient(_ stub: StubURLProtocol.Session, chainId: UInt64 = 1) -> EthereumRPCClient {
        EthereumRPCClient(endpoint: URL(string: "https://example.com/rpc")!, chainId: chainId, session: stub.urlSession)
    }

    private func capturedEnvelope(_ stub: StubURLProtocol.Session) throws -> [String: Any] {
        let body = try #require(stub.capturedBody)
        return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    @Test func initStoresTheGivenChainIdDefaultingToMainnet() {
        let stub = StubURLProtocol.makeSession(response: .success(body: Data()))
        #expect(makeClient(stub).chainId == 1)
        #expect(makeClient(stub, chainId: 11155111).chainId == 11155111)
    }

    // MARK: - nativeBalance

    @Test func nativeBalanceParsesTheQuantityHexResponse() async throws {
        let stub = stubbedResult("0x1a")
        #expect(try await makeClient(stub).nativeBalance(of: someAddress) == 26)
    }

    @Test func nativeBalanceAcceptsAnOddDigitCountQuantity() async throws {
        // "Quantity" hex (unlike "Data" hex) is minimal-digit, so an odd
        // count is valid, e.g. "0x1" for 1 wei.
        let stub = stubbedResult("0x1")
        #expect(try await makeClient(stub).nativeBalance(of: someAddress) == 1)
    }

    @Test func nativeBalanceOfZeroIsZero() async throws {
        let stub = stubbedResult("0x0")
        #expect(try await makeClient(stub).nativeBalance(of: someAddress) == 0)
    }

    @Test func nativeBalanceThrowsDecodingFailedForInvalidQuantityHex() async throws {
        let client = makeClient(stubbedResult("0xzz"))
        await #expect(throws: BlockchainClientError.self) {
            _ = try await client.nativeBalance(of: someAddress)
        }
    }

    @Test func nativeBalanceSendsEthGetBalanceWithTheAddressAndLatestTag() async throws {
        let stub = stubbedResult("0x0")
        _ = try await makeClient(stub).nativeBalance(of: someAddress)

        let envelope = try capturedEnvelope(stub)
        #expect(envelope["method"] as? String == "eth_getBalance")
        #expect(envelope["params"] as? [String] == [someAddress.string, "latest"])
    }

    // MARK: - call

    @Test func callSendsEthCallWithTheToAndDataObjectAndTheLatestTag() async throws {
        let stub = stubbedResult("0x")
        _ = try await makeClient(stub).call(to: someAddress, data: Data([0xDE, 0xAD]))

        let envelope = try capturedEnvelope(stub)
        #expect(envelope["method"] as? String == "eth_call")

        let params = try #require(envelope["params"] as? [Any])
        #expect(params.count == 2)
        #expect(params[1] as? String == "latest")

        let callObject = try #require(params[0] as? [String: Any])
        #expect(callObject["to"] as? String == someAddress.string)
        #expect(callObject["data"] as? String == "0xdead")
    }

    @Test func callReturnsTheDecodedRawReturnData() async throws {
        let stub = stubbedResult("0xdeadbeef")
        let result = try await makeClient(stub).call(to: someAddress, data: Data())
        #expect(result == Data([0xDE, 0xAD, 0xBE, 0xEF]))
    }

    // MARK: - erc20Balance

    @Test func erc20BalanceSendsTheBalanceOfSelectorAndOwnerWord() async throws {
        let stub = stubbedResult(word(BigUInt(0)).hexEncoded)
        _ = try await makeClient(stub).erc20Balance(token: someAddress, owner: someOtherAddress)

        let envelope = try capturedEnvelope(stub)
        let params = try #require(envelope["params"] as? [Any])
        let callObject = try #require(params[0] as? [String: Any])
        #expect(callObject["to"] as? String == someAddress.string)

        let expectedData = EthereumABI.encodeCall(
            selector: EthereumABI.selector("balanceOf(address)"),
            parameters: [.address(someOtherAddress)]
        )
        #expect(callObject["data"] as? String == expectedData.hexEncoded)
    }

    @Test func erc20BalanceDecodesTheReturnedWordAsAUInt256() async throws {
        let balance = BigUInt(123_456_789)
        let stub = stubbedResult(word(balance).hexEncoded)
        #expect(try await makeClient(stub).erc20Balance(token: someAddress, owner: someOtherAddress) == balance)
    }

    @Test func erc20BalanceThrowsDecodingFailedOnAnEmptyResponse() async throws {
        let client = makeClient(stubbedResult("0x"))
        await #expect(throws: BlockchainClientError.self) {
            _ = try await client.erc20Balance(token: someAddress, owner: someOtherAddress)
        }
    }

    // MARK: - latestRoundData

    @Test func latestRoundDataDecodesAllFiveWords() async throws {
        let roundId = BigUInt(7)
        let answer = BigInt(-12345) // negative — exercises decodeInt256's two's-complement path.
        let startedAt = BigUInt(1_000)
        let updatedAt = BigUInt(2_000)
        let answeredInRound = BigUInt(7)

        let responseData = word(roundId) + word(answer) + word(startedAt) + word(updatedAt) + word(answeredInRound)
        let stub = stubbedResult(responseData.hexEncoded)

        let result = try await makeClient(stub).latestRoundData(feed: someAddress)
        #expect(result.roundId == roundId)
        #expect(result.answer == answer)
        #expect(result.startedAt == startedAt)
        #expect(result.updatedAt == updatedAt)
        #expect(result.answeredInRound == answeredInRound)
    }

    @Test func latestRoundDataSendsTheLatestRoundDataSelectorWithNoParameters() async throws {
        let responseData = Data(repeating: 0, count: 32 * 5)
        let stub = stubbedResult(responseData.hexEncoded)
        _ = try await makeClient(stub).latestRoundData(feed: someAddress)

        let envelope = try capturedEnvelope(stub)
        let params = try #require(envelope["params"] as? [Any])
        let callObject = try #require(params[0] as? [String: Any])
        #expect(callObject["data"] as? String == EthereumABI.selector("latestRoundData()").hexEncoded)
    }

    @Test func latestRoundDataThrowsDecodingFailedWhenFewerThanFiveWordsAreReturned() async throws {
        let tooShort = word(BigUInt(1)) + word(BigUInt(2))
        let client = makeClient(stubbedResult(tooShort.hexEncoded))
        await #expect(throws: BlockchainClientError.self) {
            _ = try await client.latestRoundData(feed: someAddress)
        }
    }

    // MARK: - broadcast

    @Test func broadcastSendsTheRawTransactionHexAndReturnsTheHash() async throws {
        let txHash = "0x" + String(repeating: "ab", count: 32)
        let stub = stubbedResult(txHash)

        let signedTransaction = Data([0x01, 0x02, 0x03])
        let result = try await makeClient(stub).broadcast(signedTransaction)
        #expect(result == txHash)

        let envelope = try capturedEnvelope(stub)
        #expect(envelope["method"] as? String == "eth_sendRawTransaction")
        #expect(envelope["params"] as? [String] == [signedTransaction.hexEncoded])
    }

    @Test func broadcastThrowsRPCErrorWhenTheNodeRejectsTheTransaction() async throws {
        let body = #"{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"nonce too low"}}"#
        let client = makeClient(StubURLProtocol.makeSession(response: .success(body: Data(body.utf8))))

        do {
            _ = try await client.broadcast(Data([0x01]))
            Issue.record("expected broadcast(_:) to throw")
        } catch let error as BlockchainClientError {
            #expect(error == .rpcError(code: -32000, message: "nonce too low"))
        }
    }
}
