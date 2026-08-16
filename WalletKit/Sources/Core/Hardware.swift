//
//  Hardware.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 16/08/2026.
//

/// A supported hardware wallet manufacturer.
public enum HardwareVendor: Equatable, CaseIterable {
    /// A Trezor device.
    case trezor
}

/// A physical/logical transport a hardware device can be reached over.
public enum HardwareTransportKind: Equatable, CaseIterable {
    /// A wired USB connection.
    case usb

    /// A Bluetooth connection.
    case bluetooth

    /// An air-gapped connection via QR code exchange (no direct
    /// electrical/radio link to the device).
    case qrAirGap
}

/// Static, connection-independent metadata describing a discovered or
/// connected hardware device.
public struct HardwareDeviceInfo: Equatable {
    /// A stable identifier for this device, e.g. its USB serial number.
    public let id: String

    /// The device's manufacturer.
    public let vendor: HardwareVendor

    /// The transport this info was discovered/connected over.
    public let transport: HardwareTransportKind

    /// The device's model name, e.g. `"Trezor Model T"`.
    public let model: String

    /// The user-assigned label shown on the device, if any.
    public let label: String?

    /// The device's current firmware version string, if known.
    public let firmwareVersion: String?

    /// Whether the device's firmware is below the minimum version this
    /// library supports and should be updated before use.
    public let needsFirmwareUpdate: Bool

    /// Creates a hardware device info value.
    ///
    /// - Parameters:
    ///   - id: A stable identifier for this device, e.g. its USB serial
    ///     number.
    ///   - vendor: The device's manufacturer.
    ///   - transport: The transport this info was discovered/connected
    ///     over.
    ///   - model: The device's model name, e.g. `"Trezor Model T"`.
    ///   - label: The user-assigned label shown on the device, if any.
    ///   - firmwareVersion: The device's current firmware version string,
    ///     if known.
    ///   - needsFirmwareUpdate: Whether the device's firmware is below the
    ///     minimum version this library supports and should be updated
    ///     before use.
    public init(
        id: String,
        vendor: HardwareVendor,
        transport: HardwareTransportKind,
        model: String,
        label: String?,
        firmwareVersion: String?,
        needsFirmwareUpdate: Bool
    ) {
        self.id = id
        self.vendor = vendor
        self.transport = transport
        self.model = model
        self.label = label
        self.firmwareVersion = firmwareVersion
        self.needsFirmwareUpdate = needsFirmwareUpdate
    }
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

/// Callbacks a ``HardwareDevice`` uses to relay user-interaction requests
/// and lifecycle events back to the app.
public protocol HardwareDeviceDelegate: AnyObject {
    /// Called when `device` needs the user to provide a piece of input
    /// (a PIN or passphrase).
    ///
    /// - Parameters:
    ///   - device: The device requesting input.
    ///   - request: What kind of input is being requested.
    /// - Returns: The user-provided value, or `nil` if the user cancelled.
    func hardwareDevice(_ device: HardwareDevice, needsInput request: HardwareInputRequest) async -> String?

    /// Called when `device` is waiting for the user to physically confirm
    /// something on the device itself.
    ///
    /// - Parameters:
    ///   - device: The device waiting for confirmation.
    ///   - request: What's being confirmed.
    func hardwareDevice(_ device: HardwareDevice, waitingForConfirmation request: HardwareButtonRequest) async

    /// Called when `device` disconnects, whether initiated by the app
    /// (``HardwareDevice/disconnect()``) or externally (e.g. the user
    /// unplugged it).
    ///
    /// - Parameter device: The device that disconnected.
    func hardwareDeviceDidDisconnect(_ device: HardwareDevice)
}

/// A connected hardware wallet, acting as a ``KeyProvider`` for its keys.
public protocol HardwareDeviceProtocol: KeyProvider {
    /// Static metadata describing this device.
    var info: HardwareDeviceInfo { get }

    /// Whether this device is still connected.
    var isConnected: Bool { get }

    /// Disconnects from this device.
    func disconnect() async
}

/// A connected hardware wallet.
///
/// Obtained from ``HardwareDeviceManager/connect(_:delegate:)``.
public final class HardwareDevice: HardwareDeviceProtocol {
    /// Static metadata describing this device.
    public let info: HardwareDeviceInfo

    /// Whether this device is still connected.
    public private(set) var isConnected: Bool

    private weak var delegate: HardwareDeviceDelegate?

    init(info: HardwareDeviceInfo, delegate: HardwareDeviceDelegate?) {
        self.info = info
        self.delegate = delegate
        self.isConnected = true
    }

    /// Where this device's key material lives — always
    /// ``KeySource/hardware(_:)`` with this device's ``info``.
    public var source: KeySource { .hardware(info) }

    /// Reads the public key at `path` for `curve` from the device.
    ///
    /// - Parameters:
    ///   - path: The derivation path to read the public key at.
    ///   - curve: The elliptic curve to derive under.
    /// - Returns: The public key at `path`.
    public func publicKey(path: DerivationPath, curve: Curve) async throws -> PublicKey {
        throw WalletKitError.deviceDisconnected
    }

    /// Builds the ``Account`` for `blockchain` at index `account` from the
    /// device.
    ///
    /// - Parameters:
    ///   - blockchain: The blockchain to build the account for.
    ///   - account: The BIP44-style account index.
    /// - Returns: The resulting account, including its derived public key.
    public func account(_ blockchain: Blockchain, account: UInt32 = 0) async throws -> Account {
        throw WalletKitError.deviceDisconnected
    }

    /// Disconnects from this device and notifies the delegate.
    public func disconnect() async {
        isConnected = false
        delegate?.hardwareDeviceDidDisconnect(self)
    }
}

/// Discovers and connects to hardware wallets.
public protocol HardwareDeviceManagerProtocol: AnyObject {
    /// Scans for connected/reachable hardware devices.
    ///
    /// - Parameters:
    ///   - vendors: Which manufacturers to look for.
    ///   - transports: Which transports to scan over. Must be non-empty.
    /// - Returns: Info for every discovered device.
    func scan(vendors: [HardwareVendor], transports: [HardwareTransportKind]) async throws -> [HardwareDeviceInfo]

    /// Connects to a previously discovered device.
    ///
    /// - Parameters:
    ///   - info: The device to connect to, as returned by ``scan``.
    ///   - delegate: The delegate to relay input/confirmation requests and
    ///     disconnection events to.
    /// - Returns: The connected device.
    func connect(_ info: HardwareDeviceInfo, delegate: HardwareDeviceDelegate) async throws -> HardwareDevice
}

/// Discovers and connects to hardware wallets.
///
/// - Note: No real transport (USB/Bluetooth) integration exists yet —
///   ``scan(vendors:transports:)`` always succeeds with an empty result,
///   and ``connect(_:delegate:)`` always throws
///   ``WalletKitError/deviceNotFound``.
public final class HardwareDeviceManager: HardwareDeviceManagerProtocol {
    public init() {}

    /// Scans for connected/reachable hardware devices.
    ///
    /// - Parameters:
    ///   - vendors: Which manufacturers to look for. Defaults to every
    ///     supported vendor.
    ///   - transports: Which transports to scan over. Must be non-empty.
    ///     Defaults to USB and Bluetooth.
    /// - Returns: Info for every discovered device. Currently always empty
    ///   — see the type-level note.
    /// - Throws: ``WalletKitError/transportUnavailable(reason:)`` if
    ///   `transports` is empty.
    public func scan(
        vendors: [HardwareVendor] = HardwareVendor.allCases,
        transports: [HardwareTransportKind] = [.usb, .bluetooth]
    ) async throws -> [HardwareDeviceInfo] {
        guard !transports.isEmpty else {
            throw WalletKitError.transportUnavailable(reason: "no transports requested")
        }
        // No real transport (USB/Bluetooth) integration yet, so nothing is
        // ever discovered — correct behavior with no device connected.
        return []
    }

    /// Connects to a previously discovered device.
    ///
    /// - Parameters:
    ///   - info: The device to connect to, as returned by ``scan``.
    ///   - delegate: The delegate to relay input/confirmation requests and
    ///     disconnection events to.
    /// - Returns: The connected device.
    /// - Throws: Currently always throws
    ///   ``WalletKitError/deviceNotFound`` — see the type-level note.
    public func connect(_ info: HardwareDeviceInfo, delegate: HardwareDeviceDelegate) async throws -> HardwareDevice {
        throw WalletKitError.deviceNotFound
    }
}
