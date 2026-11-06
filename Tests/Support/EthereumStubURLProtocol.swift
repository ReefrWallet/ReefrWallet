import Foundation

/// Answers Ethereum JSON-RPC `eth_call`s from a handler, for an `EthereumRPCClient` over a session built
/// with ``make(handler:)``. Handlers are keyed by a per-session host so parallel tests don't share state.
final class EthereumStubURLProtocol: URLProtocol, @unchecked Sendable {
    /// One `eth_call`, with lowercased `to` and `0x`-prefixed `data`.
    struct Call: Equatable {
        let to: String
        let data: String
    }

    struct Stub {
        let endpoint: URL
        let session: URLSession

        func calls() -> [Call] {
            EthereumStubURLProtocol.calls(host: endpoint.host ?? "")
        }
    }

    /// Returns the `0x` hex result for a call, or `nil` for a JSON-RPC error.
    typealias Handler = @Sendable (Call) -> String?

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]
    nonisolated(unsafe) private static var captured: [String: [Call]] = [:]

    static func make(handler: @escaping Handler) -> Stub {
        let host = "ethereum-\(UUID().uuidString.lowercased()).test"

        lock.lock()
        handlers[host] = handler
        lock.unlock()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EthereumStubURLProtocol.self]

        return Stub(endpoint: URL(string: "https://\(host)")!, session: URLSession(configuration: configuration))
    }

    static func calls(host: String) -> [Call] {
        lock.lock()
        defer { lock.unlock() }

        return captured[host] ?? []
    }

    override static func canInit(with request: URLRequest) -> Bool { true }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host ?? ""
        let call = Self.decodeCall(from: request)

        Self.lock.lock()
        let handler = Self.handlers[host]

        if let call {
            Self.captured[host, default: []].append(call)
        }

        Self.lock.unlock()

        let body: String

        if let call, let result = handler?(call) {
            body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":\"\(result)\"}"
        } else {
            body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32000,\"message\":\"stub: no result\"}}"
        }

        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func decodeCall(from request: URLRequest) -> Call? {
        guard let data = body(of: request),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["method"] as? String == "eth_call",
              let params = object["params"] as? [Any],
              let transaction = params.first as? [String: Any],
              let to = transaction["to"] as? String
        else {
            return nil
        }

        let calldata = (transaction["data"] as? String) ?? (transaction["input"] as? String) ?? "0x"
        return Call(to: to.lowercased(), data: calldata.lowercased())
    }

    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }

        guard let stream = request.httpBodyStream else {
            return nil
        }

        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)

        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)

            guard count > 0 else {
                break
            }

            data.append(buffer, count: count)
        }

        return data
    }
}
