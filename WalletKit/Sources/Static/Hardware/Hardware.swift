//
//  Hardware.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 16/08/2026.
//

import WalletKitRust

/// A supported hardware wallet manufacturer.
public enum HardwareVendor: String, Codable, CaseIterable {
    case trezor

    init(_ raw: HardwareVendorFfi) {
        switch raw {
        case .trezor:
            self = .trezor
        }
    }

    var raw: HardwareVendorFfi {
        switch self {
        case .trezor: .trezor
        }
    }
}

// These are plain data types with no cryptography or FFI-object handle
// involved, so — unlike ``HardwareVendor`` — they're UniFFI-generated and
// re-exported as-is rather than hand-wrapped; see `Docs/Overview.md`'s
// "FFI / bindings strategy".

/// A physical/logical transport a hardware device can be reached over.
@_exported import enum WalletKitRust.HardwareTransportKind

/// A piece of input a hardware device is asking the user to provide,
/// relayed to the app via ``HardwareDeviceDelegate``.
@_exported import enum WalletKitRust.HardwareInputRequest

/// A physical confirmation the device is waiting for the user to perform
/// on its own screen/buttons, relayed to the app via
/// ``HardwareDeviceDelegate`` so the UI can show "check your device"-style
/// messaging.
@_exported import enum WalletKitRust.HardwareButtonRequest
