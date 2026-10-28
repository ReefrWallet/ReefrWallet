//
//  CardanoDappProvider+Support.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 27.10.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import WalletKit

// MARK: - Arguments and errors

extension CardanoDappProvider {
    enum ErrorKind {
        case api
        case dataSign
        case txSign
    }

    /// Re-validates the approved request right before key material is touched.
    func authorizer(
        _ context: DappRequestContext,
        account: Account
    ) -> @Sendable () async throws(DappError) -> Void {
        { () async throws(DappError) in try await context.authorize(.cardano, account: account) }
    }

    func transactionBytes(_ arguments: [JSONValue], at index: Int) throws(CardanoDappError) -> Data {
        guard index < arguments.count, let text = arguments[index].stringValue, let bytes = decodeHexData(text) else {
            throw .invalidRequest("Expected a hex transaction.")
        }

        return bytes
    }

    func optionalString(_ arguments: [JSONValue], at index: Int) throws(CardanoDappError) -> String? {
        guard index < arguments.count, arguments[index] != .null else {
            return nil
        }

        guard let text = arguments[index].stringValue else {
            throw .invalidRequest("Expected a hex string.")
        }

        return text
    }

    func pagination(_ arguments: [JSONValue], at index: Int) throws(CardanoDappError) -> (page: Int, limit: Int)? {
        guard index < arguments.count, arguments[index] != .null else {
            return nil
        }

        guard
            let object = arguments[index].objectValue,
            let page = object["page"]?.numberValue, let limit = object["limit"]?.numberValue,
            page >= 0, limit > 0, page.rounded() == page, limit.rounded() == limit
        else {
            throw .invalidRequest("Pagination expects {page, limit} with a non-negative page and a positive limit.")
        }

        return (Int(page), Int(limit))
    }

    /// Runs `operation`, mapping any error to the code space of `kind`.
    func call<T>(_ kind: ErrorKind = .api, _ operation: () async throws -> T) async throws(CardanoDappError) -> T {
        do {
            return try await operation()
        } catch {
            throw Self.convert(error, kind)
        }
    }

    func call<T>(_ kind: ErrorKind = .api, _ operation: () throws -> T) throws(CardanoDappError) -> T {
        do {
            return try operation()
        } catch {
            throw Self.convert(error, kind)
        }
    }

    static func convert(_ error: any Error, _ kind: ErrorKind) -> CardanoDappError {
        if let error = error as? CardanoDappError {
            return error
        }

        guard let dappError = error as? DappError else {
            return internalFailure("\(error)", kind)
        }

        switch dappError {
        case let .cardano(error):
            return error
        case .disconnected, .unauthorized:
            return .accountChanged
        case let .invalidParams(reason):
            return .invalidRequest(reason)
        case .userRejected:
            switch kind {
            case .api: return .refused
            case .dataSign: return .dataSign(.userDeclined, "The user declined.")
            case .txSign: return .txSign(.userDeclined, "The user declined.")
            }

        case .chainNotFound, .unsupportedMethod:
            return .invalidRequest(dappError.errorDescription ?? "Unsupported request.")
        case let .internalError(reason):
            return internalFailure(reason, kind)
        }
    }

    static func internalFailure(_ reason: String, _ kind: ErrorKind) -> CardanoDappError {
        switch kind {
        case .api: .internalError(reason)
        case .dataSign: .dataSign(.proofGeneration, reason)
        case .txSign: .txSign(.proofGeneration, reason)
        }
    }
}

// MARK: - Support

/// The account each origin enabled, so a later account switch is noticed even
/// though the session carries the permission forward.
actor CardanoEnabledAccounts {
    private var addresses: [String: String] = [:]

    func address(origin: String) -> String? { addresses[origin] }

    func set(_ address: String, origin: String) { addresses[origin] = address }
}

extension Data {
    /// Bare lowercase hex, as CIP-30 exchanges bytes.
    var cardanoHex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
