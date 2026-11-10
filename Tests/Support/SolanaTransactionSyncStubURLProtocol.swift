import Foundation

final class SolanaTransactionSyncStubURLProtocol: URLProtocol, @unchecked Sendable {
    static let owner = "EughZHHocZurATvg543M3w3PdT177yfgmLuxL2G4CRWD"
    static let signature = "32ZRJJGrrmjCyMKyMrSqvWSiNSPWfwq6yLUjwkeUFZXbymyzDDSjxVxDofwfGSCAHwitDQAhxkg6mJJWCfJhqhpV"

    private static let lock = NSLock()
    private static var transactionRequestCount = 0

    struct Stub {
        let endpoint: URL
        let session: URLSession

        var transactionRequests: Int {
            SolanaTransactionSyncStubURLProtocol.lock.lock()
            defer { SolanaTransactionSyncStubURLProtocol.lock.unlock() }
            return SolanaTransactionSyncStubURLProtocol.transactionRequestCount
        }
    }

    static func make() -> Stub {
        lock.lock()
        transactionRequestCount = 0
        lock.unlock()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Self.self]
        let endpoint = URL(string: "https://solana-history.test")!
        return Stub(endpoint: endpoint, session: URLSession(configuration: configuration))
    }

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "solana-history.test"
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.response(for: request))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private extension SolanaTransactionSyncStubURLProtocol {
    static func response(for request: URLRequest) -> Data {
        guard let requestBody = requestBody(for: request),
              let rawBody = try? JSONSerialization.jsonObject(with: requestBody),
              let body = rawBody as? [String: Any],
              let method = body["method"] as? String
        else {
            return errorResponse
        }

        switch method {
        case "getBalance":
            return json("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"context\":{\"slot\":10},\"value\":10000}}")
        case "getSignaturesForAddress":
            guard let params = body["params"] as? [Any],
                  params.count > 1,
                  let config = params[1] as? [String: Any]
            else {
                return errorResponse
            }

            let before = config["before"] as? String
            let result = before == nil ? "[{\"signature\":\"\(signature)\",\"slot\":10,\"err\":null}]" : "[]"
            return json("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":\(result)}")
        case "getSlot":
            return json("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":10}")
        case "getTokenAccountsByOwner":
            return json("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"context\":{\"slot\":10},\"value\":[]}}")
        case "getTransaction":
            lock.lock()
            transactionRequestCount += 1
            let requestCount = transactionRequestCount
            lock.unlock()

            if requestCount == 1 {
                return json("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":null}")
            }

            return json("""
            {"jsonrpc":"2.0","id":1,"result":{"slot":10,"blockTime":1794231827,"transaction":{"message":{"accountKeys":[{"pubkey":"yhVjQ8ev2dk8NjWY53QiKPdxhTaC4BbqMTuBEXoiMcy","signer":true},{"pubkey":"\(owner)","signer":false}],"instructions":[]}},"meta":{"err":null,"fee":5000,"preBalances":[0,0],"postBalances":[0,10000],"preTokenBalances":[],"postTokenBalances":[]}}}
            """)
        default:
            return errorResponse
        }
    }

    static var errorResponse: Data {
        json("{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32601,\"message\":\"unsupported method\"}}")
    }

    static func json(_ string: String) -> Data {
        Data(string.utf8)
    }

    static func requestBody(for request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }

        guard let stream = request.httpBodyStream else {
            return nil
        }

        stream.open()
        defer { stream.close() }

        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)

        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else {
                return nil
            }

            guard count > 0 else {
                break
            }

            body.append(buffer, count: count)
        }

        return body
    }
}
