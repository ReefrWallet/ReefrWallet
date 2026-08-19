//
//  MoyaProvider+Async.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 21.12.25.
//  Copyright © 2025 Reefr Wallet. All rights reserved.
//

import Foundation
import Moya

public extension MoyaProvider {
    func request<T>(_ target: Target) async throws -> T where T: Decodable {
        try await withCheckedThrowingContinuation { continuation in
            self.request(target) { result in
                switch result {
                case .success(let response):
                    let decoder = JSONDecoder()
                    decoder.keyDecodingStrategy = .convertFromSnakeCase

                    do {
                        let decoded = try decoder.decode(T.self, from: response.data)
                        continuation.resume(returning: decoded)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
