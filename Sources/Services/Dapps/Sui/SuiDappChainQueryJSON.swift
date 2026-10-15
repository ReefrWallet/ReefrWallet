//
//  SuiDappChainQueryJSON.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 02.10.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//
//  JSON mapping for SuiDappProvider's chain-query results
//  (getCoins/getObjects/getMoveFunction) — split out from
//  SuiDappProvider.swift purely to keep that file under its line-count
//  limit; every function here is a pure WalletKit-type-to-JSONValue
//  mapper with no dependency on the provider itself.

import WalletKit

enum SuiDappChainQueryJSON {
    static func jsonValue(_ coin: SuiCoinObject) -> JSONValue {
        .object([
            "objectId": .string("0x" + coin.reference.objectId.map { String(format: "%02x", $0) }.joined()),
            "version": .string(String(coin.reference.version)),
            "digest": .string(coin.reference.digest.base64EncodedString()),
            "balance": .string(String(coin.balance))
        ])
    }

    static func jsonValue(_ object: SuiObjectInfo) -> JSONValue {
        .object([
            "objectId": .string("0x" + object.objectId.map { String(format: "%02x", $0) }.joined()),
            "version": .string(String(object.version)),
            "digest": .string(object.digest.base64EncodedString()),
            "owner": jsonValue(object.owner)
        ])
    }

    static func jsonValue(_ owner: SuiObjectInfo.Owner) -> JSONValue {
        switch owner {
        case let .address(address):
            return .object(["kind": .string("address"), "address": .string(address.string)])
        case let .object(address):
            return .object(["kind": .string("object"), "address": .string(address.string)])
        case .immutable:
            return .object(["kind": .string("immutable")])
        case let .shared(initialSharedVersion):
            return .object(["kind": .string("shared"), "initialSharedVersion": .string(String(initialSharedVersion))])
        case .unsupported:
            return .object(["kind": .string("unsupported")])
        }
    }

    static func jsonValue(_ parameter: SuiMoveParameter) -> JSONValue {
        let reference: String
        switch parameter.reference {
        case .none: reference = "none"
        case .immutable: reference = "immutable"
        case .mutable: reference = "mutable"
        }

        return .object(["reference": .string(reference), "type": jsonValue(parameter.body)])
    }

    static func jsonValue(_ body: SuiMoveTypeBody) -> JSONValue {
        switch body {
        case .address: return .object(["kind": .string("address")])
        case .bool: return .object(["kind": .string("bool")])
        case .u8: return .object(["kind": .string("u8")])
        case .u16: return .object(["kind": .string("u16")])
        case .u32: return .object(["kind": .string("u32")])
        case .u64: return .object(["kind": .string("u64")])
        case .u128: return .object(["kind": .string("u128")])
        case .u256: return .object(["kind": .string("u256")])
        case let .vector(element):
            return .object(["kind": .string("vector"), "elementType": jsonValue(element)])
        case let .datatype(typeName, typeParameters):
            return .object([
                "kind": .string("datatype"),
                "typeName": .string(typeName),
                "typeParameters": .array(typeParameters.map(jsonValue))
            ])
        case let .typeParameter(index):
            return .object(["kind": .string("typeParameter"), "index": .number(Double(index))])
        case .unsupported:
            return .object(["kind": .string("unsupported")])
        }
    }
}
