import Foundation

/// Serves canned Blockscout pages keyed by path and query, per stub host.
final class BlockscoutStubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Stub {
        let host: String
        let configuration: URLSessionConfiguration

        func requests(path: String) -> [URLRequest] {
            BlockscoutStubURLProtocol.requests(host: host).filter { $0.url?.path == "/api/v2/addresses/\(path)" }
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [String: [String: String]] = [:]
    nonisolated(unsafe) private static var captured: [String: [URLRequest]] = [:]

    /// `routes` maps `"<address>/<list>"` or `"<address>/<list>?<sorted query>"` to a JSON body.
    static func make(routes: [String: String]) -> Stub {
        let host = "blockscout-\(UUID().uuidString.lowercased()).test"
        lock.withLock { self.routes[host] = routes }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BlockscoutStubURLProtocol.self]
        return Stub(host: host, configuration: configuration)
    }

    static func requests(host: String) -> [URLRequest] {
        lock.withLock { captured[host] ?? [] }
    }

    override static func canInit(with request: URLRequest) -> Bool { true }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let host = url.host ?? ""
        let list = url.path.replacingOccurrences(of: "/api/v2/addresses/", with: "")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .filter { $0.name != "type" }
            .map { "\($0.name)=\($0.value ?? "")" }
            .sorted()
            .joined(separator: "&")

        let key = query.flatMap { $0.isEmpty ? nil : "\(list)?\($0)" } ?? list
        let body = Self.lock.withLock { () -> String? in
            Self.captured[host, default: []].append(request)
            return Self.routes[host]?[key]
        }

        let status = body == nil ? 404 : 200
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((body ?? "not found").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Blockscout API v2 JSON for the stubbed pages.
enum BlockscoutFixtures {
    static let owner = "0x261B90cA1f43BaE342e6a55192A514E1eDa1CE0d"
    static let usdc = "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238"

    static func transaction(hash: String, block: Int, sender: String = owner) -> String {
        """
        {"block_number":\(block),"fee":{"value":"21"},"from":{"hash":"\(sender)"},"hash":"\(hash)","method":"approve",
         "status":"ok","timestamp":"2026-01-01T00:00:00.000000Z","to":{"hash":"0xbbbb"},"value":"5"}
        """
    }

    static func pending(hash: String) -> String {
        """
        {"block_number":null,"fee":{"value":"21"},"from":{"hash":"\(owner)"},"hash":"\(hash)","method":null,
         "status":null,"timestamp":null,"to":{"hash":"0xbbbb"},"value":"5"}
        """
    }

    static func transfer(hash: String, block: Int, value: String) -> String {
        """
        {"block_number":\(block),"from":{"hash":"0xaaaa"},"log_index":3,"timestamp":"2026-01-01T00:00:00.000000Z",
         "to":{"hash":"\(owner)"},"token":{"address_hash":"\(usdc)","decimals":"6","name":"USDC","symbol":"USDC"},
         "total":{"value":"\(value)"},"transaction_hash":"\(hash)"}
        """
    }

    static func list(_ items: [String], next: String? = nil) -> String {
        "{\"items\":[\(items.joined(separator: ","))],\"next_page_params\":\(next ?? "null")}"
    }
}
