//
//  MoyaProvider+Async.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 21.12.25.
//  Copyright © 2025 Reefr Wallet. All rights reserved.
//

import Foundation
import Moya
import WalletKit

public extension MoyaProvider {
    /// Cancelling the calling task cancels the underlying request.
    func request<T>(_ target: Target) async throws -> T where T: Decodable {
        let response = try await requestResponse(target)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        return try decoder.decode(T.self, from: response.data)
    }
}
