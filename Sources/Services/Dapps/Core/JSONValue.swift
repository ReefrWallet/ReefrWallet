//
//  JSONValue.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 25.09.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation

/// A JSON value — a dapp request's `params` and a provider's result.
/// `Codable` for straightforward serialization; `Sendable` so it can
/// cross the actor boundary between `DappBridge` (`@MainActor`) and
/// `DappSession`/`DappProvider` (actors).
enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

// MARK: - Codable

extension JSONValue: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }
}

// MARK: - Foundation `Any` bridging

extension JSONValue {
    /// Converts a `WKScriptMessage.body`/`replyHandler`-shaped `Any`
    /// (bridged `NSDictionary`/`NSArray`/`NSString`/`NSNumber`/`NSNull`)
    /// into a `JSONValue`.
    init(any: Any) {
        switch any {
        case is NSNull:
            self = .null
        case let number as NSNumber:
            // A JS boolean bridges to a `CFBoolean`-backed `NSNumber`;
            // distinguish it from a numeric value by its Objective-C type
            // encoding rather than by value, so `0`/`1` aren't mistaken
            // for `false`/`true`.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }

        case let string as String:
            self = .string(string)
        case let array as [Any]:
            self = .array(array.map(JSONValue.init(any:)))
        case let dictionary as [String: Any]:
            self = .object(dictionary.mapValues(JSONValue.init(any:)))
        default:
            self = .null
        }
    }

    /// Converts this value back into a plain `Any` object graph suitable
    /// for `WKScriptMessageHandlerWithReply`'s `replyHandler` or
    /// `evaluateJavaScript`.
    var anyValue: Any {
        switch self {
        case .null: NSNull()
        case let .bool(value): value
        case let .number(value): value
        case let .string(value): value
        case let .array(value): value.map { $0.anyValue }

        case let .object(value): value.mapValues { $0.anyValue }
        }
    }
}

// MARK: - Raw JSON bytes

extension JSONValue {
    /// Decodes raw JSON bytes — e.g.
    /// ``EthereumRPCClient/request(method:params:)``'s raw `result`.
    init(data: Data) throws {
        self = JSONValue(any: try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    /// Encodes this value as raw JSON bytes — the wire format
    /// ``EthereumRPCClient/request(method:params:)`` expects for `params`.
    func encoded() throws -> Data {
        try JSONSerialization.data(withJSONObject: anyValue, options: [.fragmentsAllowed])
    }
}

// MARK: - Convenience accessors

extension JSONValue {
    /// This value as `[JSONValue]`, or `nil` if it isn't an array.
    var arrayValue: [JSONValue]? {
        if case let .array(value) = self {
            return value
        }

        return nil
    }

    /// This value as `[String: JSONValue]`, or `nil` if it isn't an object.
    var objectValue: [String: JSONValue]? {
        if case let .object(value) = self {
            return value
        }

        return nil
    }

    /// This value as a `String`, or `nil` if it isn't a string.
    var stringValue: String? {
        if case let .string(value) = self {
            return value
        }

        return nil
    }

    /// This value as a `Double`, or `nil` if it isn't a number.
    var numberValue: Double? {
        if case let .number(value) = self {
            return value
        }

        return nil
    }

    /// This value as a `Bool`, or `nil` if it isn't a boolean.
    var boolValue: Bool? {
        if case let .bool(value) = self {
            return value
        }

        return nil
    }

    /// Looks up `key` in this value's object, or `nil` if this isn't an
    /// object or has no such key.
    subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    /// Looks up `index` in this value's array, or `nil` if this isn't an
    /// array or `index` is out of range.
    subscript(index: Int) -> JSONValue? {
        guard let array = arrayValue, array.indices.contains(index) else {
            return nil
        }

        return array[index]
    }
}
