import Foundation

/// Serves canned Blockfrost responses by path, for `CardanoClient` over a
/// session built with ``session(routes:)``. Routes are keyed by a per-session
/// host so parallel tests don't share state.
final class CardanoStubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Stub {
        let endpoint: URL
        let session: URLSession

        func requestCount(path: String) -> Int {
            CardanoStubURLProtocol.requests(host: endpoint.host ?? "").filter { $0.url?.path == path }.count
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [String: [String: (Int, Data)]] = [:]
    nonisolated(unsafe) private static var captured: [String: [URLRequest]] = [:]

    /// `routes` maps a path (`/api/v0/...`) to its JSON body; others return 404.
    static func make(routes: [String: String], status: [String: Int] = [:]) -> Stub {
        let host = "cardano-\(UUID().uuidString.lowercased()).test"
        var table = routes.mapValues { (200, Data($0.utf8)) }
        for (path, code) in status {
            table[path] = (code, table[path]?.1 ?? Data())
        }
        lock.lock()
        self.routes[host] = table
        lock.unlock()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CardanoStubURLProtocol.self]

        return Stub(
            endpoint: URL(string: "https://\(host)/api/v0")!,
            session: URLSession(configuration: configuration)
        )
    }

    static func requests(host: String) -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }

        return captured[host] ?? []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host ?? ""
        let path = request.url?.path ?? ""
        Self.lock.lock()
        Self.captured[host, default: []].append(request)
        let route = Self.routes[host]?[path]
        Self.lock.unlock()

        let (status, body) = route ?? (404, Data("not found".utf8))
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
