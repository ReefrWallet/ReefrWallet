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

        /// The most requests for `path` that were ever in flight at once.
        func maxConcurrentRequests(path: String) -> Int {
            CardanoStubURLProtocol.peak(host: endpoint.host ?? "", path: path)
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [String: [String: (Int, Data)]] = [:]
    nonisolated(unsafe) private static var captured: [String: [URLRequest]] = [:]
    nonisolated(unsafe) private static var delays: [String: TimeInterval] = [:]
    nonisolated(unsafe) private static var inFlight: [String: Int] = [:]
    nonisolated(unsafe) private static var peaks: [String: Int] = [:]

    /// `routes` maps a path (`/api/v0/...`) to its JSON body; others return 404.
    /// `delay` holds each response back, so overlapping requests are observable.
    static func make(routes: [String: String], status: [String: Int] = [:], delay: TimeInterval = 0) -> Stub {
        let host = "cardano-\(UUID().uuidString.lowercased()).test"
        var table = routes.mapValues { (200, Data($0.utf8)) }
        for (path, code) in status {
            table[path] = (code, table[path]?.1 ?? Data())
        }

        lock.lock()
        self.routes[host] = table
        delays[host] = delay
        lock.unlock()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CardanoStubURLProtocol.self]

        return Stub(
            endpoint: URL(string: "https://\(host)/api/v0")!,
            session: URLSession(configuration: configuration)
        )
    }

    static func peak(host: String, path: String) -> Int {
        lock.lock()
        defer { lock.unlock() }

        return peaks[host + path] ?? 0
    }

    static func requests(host: String) -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }

        return captured[host] ?? []
    }

    override static func canInit(with request: URLRequest) -> Bool { true }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host ?? ""
        let path = request.url?.path ?? ""
        Self.lock.lock()
        Self.captured[host, default: []].append(request)
        let route = Self.routes[host]?[path]
        let delay = Self.delays[host] ?? 0
        let key = host + path
        Self.inFlight[key, default: 0] += 1
        Self.peaks[key] = max(Self.peaks[key] ?? 0, Self.inFlight[key] ?? 0)
        Self.lock.unlock()

        let (status, body) = route ?? (404, Data("not found".utf8))
        let url = request.url!

        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
            Self.lock.lock()
            Self.inFlight[key, default: 1] -= 1
            Self.lock.unlock()

            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
