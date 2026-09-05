//
//  Codable+Extensions.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 17.01.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation

public extension Encodable {
    func asJSONString(keyEncodingStrategy: JSONEncoder.KeyEncodingStrategy = .useDefaultKeys) throws -> String {
        let data = try encoded(keyEncodingStrategy: keyEncodingStrategy)

        guard let string = String(data: data, encoding: .utf8) else {
            throw Error.invalidData
        }

        return string
    }

    func encoded(keyEncodingStrategy: JSONEncoder.KeyEncodingStrategy = .useDefaultKeys) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.keyEncodingStrategy = keyEncodingStrategy
        return try encoder.encode(self)
    }
}

public extension Data {
    func decoded<T: Decodable>() throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: self)
    }
}

public extension String {
    func decoded<T: Decodable>() throws -> T {
        try Data(utf8).decoded()
    }
}
