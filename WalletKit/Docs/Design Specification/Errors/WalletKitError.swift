//
//  WalletKitError.swift
//  WalletKit
//
//  DESIGN SPEC — not generated code. See Walletkit/Docs/Overview.md for
//  module-level notes and architecture.
//

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

    // Hardware wallet errors
    case deviceNotFound
    case deviceDisconnected
    case deviceLocked
    case deviceBusy
    case userRejectedOnDevice
    case transportUnavailable(reason: String)
    case unsupportedDevice(reason: String)
    case firmwareOutdated(minimumVersion: String)
}
