//
//  Hardware.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 16/08/2026.
//

/// A supported hardware wallet manufacturer.
public enum HardwareVendor: Equatable, CaseIterable, Codable {
    /// A Trezor device.
    case trezor
}

/// A physical/logical transport a hardware device can be reached over.
public enum HardwareTransportKind: Equatable, CaseIterable, Codable {
    /// A wired USB connection.
    case usb

    /// A Bluetooth connection.
    case bluetooth

    /// An air-gapped connection via QR code exchange (no direct
    /// electrical/radio link to the device).
    case qrAirGap
}

/// A piece of input a hardware device is asking the user to provide,
/// relayed to the app via ``HardwareDeviceDelegate``.
public enum HardwareInputRequest: Equatable {
    /// The device wants its PIN entered. `attempt` is the 1-based attempt
    /// number for this unlock session.
    case pin(attempt: UInt32)

    /// The device wants a BIP39 passphrase (the "25th word") entered.
    case passphrase
}

/// A physical confirmation the device is waiting for the user to perform
/// on its own screen/buttons, relayed to the app via
/// ``HardwareDeviceDelegate`` so the UI can show "check your device"-style
/// messaging.
public enum HardwareButtonRequest: Equatable {
    /// The device is showing an address for the user to visually confirm.
    case confirmAddress

    /// The device is showing a public key for the user to visually
    /// confirm.
    case confirmPublicKey

    /// The device is showing transaction details for the user to review
    /// and approve.
    case confirmTransaction

    /// Some other on-device confirmation not covered by the other cases,
    /// with a human-readable description of what's being confirmed.
    case other(description: String)
}
