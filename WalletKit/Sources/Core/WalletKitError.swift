//
//  WalletKitError.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 16/08/2026.
//

// MARK: - Errors

public enum WalletKitError: Error, Equatable {
    case invalidMnemonic(reason: String)
    case invalidEntropy
    case invalidPassphrase
    case invalidDerivationPath(path: String)
    case invalidAddress(reason: String)
    case unsupportedCurve(curve: Curve)
    case unsupportedWordCount(count: UInt32)
    case signingFailed(reason: String)
    case keyNotFound
    case decryptionFailed
    case internalError(message: String)

    case deviceNotFound
    case deviceDisconnected
    case deviceLocked
    case deviceBusy
    case userRejectedOnDevice
    case transportUnavailable(reason: String)
    case unsupportedDevice(reason: String)
    case firmwareOutdated(minimumVersion: String)

    init(_ raw: WalletKitErrorFfi) {
        switch raw {
        case .InvalidMnemonic(let reason): self = .invalidMnemonic(reason: reason)
        case .InvalidEntropy: self = .invalidEntropy
        case .InvalidPassphrase: self = .invalidPassphrase
        case .InvalidDerivationPath(let path): self = .invalidDerivationPath(path: path)
        case .InvalidAddress(let reason): self = .invalidAddress(reason: reason)
        case .UnsupportedCurve(let curve): self = .unsupportedCurve(curve: curve)
        case .UnsupportedWordCount(let count): self = .unsupportedWordCount(count: count)
        case .SigningFailed(let reason): self = .signingFailed(reason: reason)
        case .KeyNotFound: self = .keyNotFound
        case .DecryptionFailed: self = .decryptionFailed
        case .InternalError(let message): self = .internalError(message: message)
        case .DeviceNotFound: self = .deviceNotFound
        case .DeviceDisconnected: self = .deviceDisconnected
        case .DeviceLocked: self = .deviceLocked
        case .DeviceBusy: self = .deviceBusy
        case .UserRejectedOnDevice: self = .userRejectedOnDevice
        case .TransportUnavailable(let reason): self = .transportUnavailable(reason: reason)
        case .UnsupportedDevice(let reason): self = .unsupportedDevice(reason: reason)
        case .FirmwareOutdated(let minimumVersion): self = .firmwareOutdated(minimumVersion: minimumVersion)
        }
    }
}

/// Runs `body`, translating any thrown `WalletKitErrorFfi` (from the raw
/// generated bindings) into the public `WalletKitError`.
func remappingWalletKitError<T>(_ body: () throws -> T) rethrows -> T {
    do {
        return try body()
    } catch let error as WalletKitErrorFfi {
        throw WalletKitError(error)
    }
}
