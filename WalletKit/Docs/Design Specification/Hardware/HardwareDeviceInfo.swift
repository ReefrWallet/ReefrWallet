//
//  HardwareDeviceInfo.swift
//  WalletKit
//
//  DESIGN SPEC — not generated code. See Walletkit/Docs/Overview.md for
//  module-level notes and architecture.
//

public struct HardwareDeviceInfo: Equatable {
    /// Stable per physical device for the duration it's known to the app
    /// (e.g. a transport-level session/serial id) — used to reconnect to
    /// the same device across `scan()` calls.
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
