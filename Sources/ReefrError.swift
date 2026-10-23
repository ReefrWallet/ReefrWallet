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
        case .alreadyExists: "The item already exists."
        case .authenticationFailed: "Authentication failed or was cancelled."
        case .clientNotAvailable: "No network client is available for this blockchain."
        case .internalError: "An internal error occurred."
        case .invalidAddress: "The address is invalid."
        case .invalidData: "The data is invalid."
        case .notFound: "The requested item was not found."
        case .notImplemented: "This feature is not implemented yet."
        case .notSupported: "This operation is not supported."
        }
    }
}
