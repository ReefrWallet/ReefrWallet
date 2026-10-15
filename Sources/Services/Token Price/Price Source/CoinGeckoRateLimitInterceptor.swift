import Alamofire
import Foundation

private actor CoinGeckoRequestGate {
    private let clock = ContinuousClock()
    private let interval = Duration.seconds(2)
    private var nextAllowed: ContinuousClock.Instant

    init() {
        nextAllowed = clock.now
    }

    func acquire() async throws {
        let now = clock.now
        let deadline = max(now, nextAllowed)
        nextAllowed = deadline.advanced(by: interval)

        guard deadline > now else {
            return
        }

        try await clock.sleep(until: deadline, tolerance: nil)
    }
}

final class CoinGeckoRateLimitInterceptor: RequestInterceptor, @unchecked Sendable {
    static let shared = CoinGeckoRateLimitInterceptor()

    private let gate = CoinGeckoRequestGate()
    private let maxRetryCount = 3

    func adapt(
        _ urlRequest: URLRequest,
        for _: Session,
        completion: @escaping (Result<URLRequest, any Error>) -> Void
    ) {
        Task {
            do {
                try await gate.acquire()
                completion(.success(urlRequest))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func retry(
        _ request: Request,
        for _: Session,
        dueTo error: any Error,
        completion: @escaping (RetryResult) -> Void
    ) {
        guard let response = request.task?.response as? HTTPURLResponse,
              [429, 503].contains(response.statusCode),
              request.retryCount < maxRetryCount else {
            completion(.doNotRetryWithError(error))
            return
        }

        completion(.retryWithDelay(retryDelay(for: response, attempt: request.retryCount)))
    }
}

private extension CoinGeckoRateLimitInterceptor {
    func retryDelay(for response: HTTPURLResponse, attempt: Int) -> TimeInterval {
        if let value = response.value(forHTTPHeaderField: "Retry-After"),
           let delay = TimeInterval(value) {
            return max(0, delay)
        }

        return min(pow(2, Double(attempt)), 60)
    }
}
