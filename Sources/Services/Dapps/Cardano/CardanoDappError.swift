//
//  CardanoDappError.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 27.10.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation

/// A CIP-30 failure with its numeric code, one per error class the page
/// sees. The provider converts every error it throws to this at its call
/// site, because ``DappProvider/wireError(_:)`` doesn't know the method.
enum CardanoDappError: LocalizedError, Equatable, Sendable {
    /// `APIError.AccountChange`: the enabling account is no longer selected.
    case accountChanged
    /// `DataSignError`.
    case dataSign(DataSignCode, String)
    /// `APIError.InternalError`.
    case internalError(String)
    /// `APIError.InvalidRequest`.
    case invalidRequest(String)
    /// `PaginateError`: `maxSize` is the total item count.
    case paginate(maxSize: Int)
    /// `APIError.Refused`.
    case refused
    /// `TxSendError`.
    case txSend(TxSendCode, String)
    /// `TxSignError`.
    case txSign(TxSignCode, String)

    enum DataSignCode: Int, Sendable {
        case proofGeneration = 1
        case addressNotPK = 2
        case userDeclined = 3
    }

    enum TxSendCode: Int, Sendable {
        case refused = 1
        case failure = 2
    }

    enum TxSignCode: Int, Sendable {
        case proofGeneration = 1
        case userDeclined = 2
    }

    /// The `{ code, info }` (or `{ maxSize }`) envelope the page script wraps.
    var wire: JSONValue {
        func envelope(_ code: Int, _ info: String) -> JSONValue {
            .object(["code": .number(Double(code)), "info": .string(info)])
        }

        switch self {
        case .accountChanged: return envelope(-4, "The selected account changed. Call enable() again.")
        case let .dataSign(code, info): return envelope(code.rawValue, info)
        case let .internalError(info): return envelope(-2, info)
        case let .invalidRequest(info): return envelope(-1, info)
        case let .paginate(maxSize): return .object(["maxSize": .number(Double(maxSize))])
        case .refused: return envelope(-3, "The request was refused.")
        case let .txSend(code, info): return envelope(code.rawValue, info)
        case let .txSign(code, info): return envelope(code.rawValue, info)
        }
    }

    var errorDescription: String? {
        switch self {
        case .accountChanged: "The connected Cardano account changed."
        case let .dataSign(_, info), let .internalError(info), let .invalidRequest(info), let .txSend(_, info),
             let .txSign(_, info): info
        case let .paginate(maxSize): "Page out of range (\(maxSize) items)."
        case .refused: "The request was refused."
        }
    }
}
