import Foundation

/// Answers `/info` with a scripted status sequence and records each attempt's
/// time and weight. One test at a time: state is static.
final class HyperliquidStubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Attempt {
        let time: ContinuousClock.Instant
        let type: String?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var attempts: [Attempt] = []
    nonisolated(unsafe) private static var statuses: [Int] = []

    static var recorded: [Attempt] {
        lock.withLock { attempts }
    }

    /// `statuses` are served in order, then 200s; a 429 carries `Retry-After: 1`.
    static func configuration(statuses: [Int] = []) -> URLSessionConfiguration {
        lock.withLock {
            attempts = []
            self.statuses = statuses
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HyperliquidStubURLProtocol.self]
        return configuration
    }

    override static func canInit(with request: URLRequest) -> Bool { true }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
        let type = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["type"] as? String

        let status = Self.lock.withLock { () -> Int in
            Self.attempts.append(Attempt(time: .now, type: type))
            return Self.statuses.isEmpty ? 200 : Self.statuses.removeFirst()
        }

        let headers = status == 429 ? ["Retry-After": "1"] : [:]
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#""default""#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
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
