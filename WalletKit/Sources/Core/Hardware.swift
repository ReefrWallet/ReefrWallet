//
//  Hardware.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 16/08/2026.
//

public enum HardwareVendor: Equatable, CaseIterable {
    case trezor
}

public enum HardwareTransportKind: Equatable, CaseIterable {
    case usb
    case bluetooth
    case qrAirGap
}

public struct HardwareDeviceInfo: Equatable {
    public let id: String
    public let vendor: HardwareVendor
    public let transport: HardwareTransportKind
    public let model: String
    public let label: String?
    public let firmwareVersion: String?
    public let needsFirmwareUpdate: Bool

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

public enum HardwareInputRequest: Equatable {
    case pin(attempt: UInt32)
    case passphrase
}

public enum HardwareButtonRequest: Equatable {
    case confirmAddress
    case confirmPublicKey
    case confirmTransaction
    case other(description: String)
}

public protocol HardwareDeviceDelegate: AnyObject {
    func hardwareDevice(_ device: HardwareDevice, needsInput request: HardwareInputRequest) async -> String?
    func hardwareDevice(_ device: HardwareDevice, waitingForConfirmation request: HardwareButtonRequest) async
    func hardwareDeviceDidDisconnect(_ device: HardwareDevice)
}

public protocol HardwareDeviceProtocol: KeyProvider {
    var info: HardwareDeviceInfo { get }
    var isConnected: Bool { get }
    func disconnect() async
}

public final class HardwareDevice: HardwareDeviceProtocol {
    public let info: HardwareDeviceInfo
    public private(set) var isConnected: Bool
    private weak var delegate: HardwareDeviceDelegate?

    init(info: HardwareDeviceInfo, delegate: HardwareDeviceDelegate?) {
        self.info = info
        self.delegate = delegate
        self.isConnected = true
    }

    public var source: KeySource { .hardware(info) }

    public func publicKey(path: DerivationPath, curve: Curve) async throws -> PublicKey {
        throw WalletKitError.deviceDisconnected
    }

    public func account(_ blockchain: Blockchain, account: UInt32 = 0) async throws -> Account {
        throw WalletKitError.deviceDisconnected
    }

    public func disconnect() async {
        isConnected = false
        delegate?.hardwareDeviceDidDisconnect(self)
    }
}

public protocol HardwareDeviceManagerProtocol: AnyObject {
    func scan(vendors: [HardwareVendor], transports: [HardwareTransportKind]) async throws -> [HardwareDeviceInfo]
    func connect(_ info: HardwareDeviceInfo, delegate: HardwareDeviceDelegate) async throws -> HardwareDevice
}

public final class HardwareDeviceManager: HardwareDeviceManagerProtocol {
    public init() {}

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

    public func connect(_ info: HardwareDeviceInfo, delegate: HardwareDeviceDelegate) async throws -> HardwareDevice {
        throw WalletKitError.deviceNotFound
    }
}
