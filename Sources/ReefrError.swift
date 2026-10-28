//
//  ReefrError.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 13.12.25.
//  Copyright © 2025 Reefr Wallet. All rights reserved.
//

import Foundation

enum ReefrError: LocalizedError {
    case alreadyExists
    case authenticationFailed
    case clientNotAvailable
    case internalError
    case invalidAddress
    case invalidData
    case notFound
    case notImplemented
    case notSupported

    var errorDescription: String? {
        switch self {
        case .alreadyExists: String(localized: .reefrErrorAlreadyExists)
        case .authenticationFailed: String(localized: .reefrErrorAuthenticationFailed)
        case .clientNotAvailable: String(localized: .reefrErrorClientNotAvailable)
        case .internalError: String(localized: .reefrErrorInternalError)
        case .invalidAddress: String(localized: .reefrErrorInvalidAddress)
        case .invalidData: String(localized: .reefrErrorInvalidData)
        case .notFound: String(localized: .reefrErrorNotFound)
        case .notImplemented: String(localized: .reefrErrorNotImplemented)
        case .notSupported: String(localized: .reefrErrorNotSupported)
        }
    }
}
