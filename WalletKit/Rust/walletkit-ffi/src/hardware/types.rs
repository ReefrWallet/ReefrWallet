//! Plain data mirrors of `walletkit-hardware`'s vendor-agnostic types,
//! exported as UniFFI Records/Enums. Most carry no `Ffi` suffix, the same
//! way `common::Curve`/`common::DerivationPath` don't — see
//! `common/mod.rs`'s doc comment. `HardwareVendorFfi`/
//! `HardwareDeviceInfoFfi` are the exception: `WalletKit` hand-wraps them
//! (`HardwareVendor`, `HardwareDeviceInfo`) rather than using them as-is,
//! so — like `EthereumSignTxFfi`/`EthereumSignatureFfi` — they get the
//! suffix.

use walletkit_hardware as hw;

/// A supported hardware wallet manufacturer.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum HardwareVendorFfi {
    Trezor,
}

impl From<HardwareVendorFfi> for hw::HardwareVendor {
    fn from(value: HardwareVendorFfi) -> Self {
        match value {
            HardwareVendorFfi::Trezor => hw::HardwareVendor::Trezor,
        }
    }
}

impl From<hw::HardwareVendor> for HardwareVendorFfi {
    fn from(value: hw::HardwareVendor) -> Self {
        match value {
            hw::HardwareVendor::Trezor => HardwareVendorFfi::Trezor,
        }
    }
}

/// A physical/logical transport a hardware device can be reached over.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum HardwareTransportKind {
    Usb,
    Bluetooth,
    QrAirGap,
}

impl From<HardwareTransportKind> for hw::HardwareTransportKind {
    fn from(value: HardwareTransportKind) -> Self {
        match value {
            HardwareTransportKind::Usb => hw::HardwareTransportKind::Usb,
            HardwareTransportKind::Bluetooth => hw::HardwareTransportKind::Bluetooth,
            HardwareTransportKind::QrAirGap => hw::HardwareTransportKind::QrAirGap,
        }
    }
}

impl From<hw::HardwareTransportKind> for HardwareTransportKind {
    fn from(value: hw::HardwareTransportKind) -> Self {
        match value {
            hw::HardwareTransportKind::Usb => HardwareTransportKind::Usb,
            hw::HardwareTransportKind::Bluetooth => HardwareTransportKind::Bluetooth,
            hw::HardwareTransportKind::QrAirGap => HardwareTransportKind::QrAirGap,
        }
    }
}

/// Static, connection-independent metadata describing a discovered or
/// connected hardware device.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct HardwareDeviceInfoFfi {
    pub id: String,
    pub vendor: HardwareVendorFfi,
    pub transport: HardwareTransportKind,
    pub model: String,
    pub label: Option<String>,
    pub firmware_version: Option<String>,
    pub needs_firmware_update: bool,
}

impl From<HardwareDeviceInfoFfi> for hw::HardwareDeviceInfo {
    fn from(value: HardwareDeviceInfoFfi) -> Self {
        hw::HardwareDeviceInfo {
            id: value.id,
            vendor: value.vendor.into(),
            transport: value.transport.into(),
            model: value.model,
            label: value.label,
            firmware_version: value.firmware_version,
            needs_firmware_update: value.needs_firmware_update,
        }
    }
}

impl From<hw::HardwareDeviceInfo> for HardwareDeviceInfoFfi {
    fn from(value: hw::HardwareDeviceInfo) -> Self {
        HardwareDeviceInfoFfi {
            id: value.id,
            vendor: value.vendor.into(),
            transport: value.transport.into(),
            model: value.model,
            label: value.label,
            firmware_version: value.firmware_version,
            needs_firmware_update: value.needs_firmware_update,
        }
    }
}

/// A piece of input a hardware device is asking the user to provide.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum HardwareInputRequest {
    Pin { attempt: u32 },
    Passphrase,
}

impl From<hw::HardwareInputRequest> for HardwareInputRequest {
    fn from(value: hw::HardwareInputRequest) -> Self {
        match value {
            hw::HardwareInputRequest::Pin { attempt } => HardwareInputRequest::Pin { attempt },
            hw::HardwareInputRequest::Passphrase => HardwareInputRequest::Passphrase,
        }
    }
}

/// A physical confirmation the device is waiting for the user to perform
/// on its own screen/buttons.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum HardwareButtonRequest {
    ConfirmAddress,
    ConfirmPublicKey,
    ConfirmTransaction,
    Other { description: String },
}

impl From<hw::HardwareButtonRequest> for HardwareButtonRequest {
    fn from(value: hw::HardwareButtonRequest) -> Self {
        match value {
            hw::HardwareButtonRequest::ConfirmAddress => HardwareButtonRequest::ConfirmAddress,
            hw::HardwareButtonRequest::ConfirmPublicKey => HardwareButtonRequest::ConfirmPublicKey,
            hw::HardwareButtonRequest::ConfirmTransaction => HardwareButtonRequest::ConfirmTransaction,
            hw::HardwareButtonRequest::Other { description } => HardwareButtonRequest::Other { description },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn vendor_round_trips_through_the_hardware_crate_type() {
        let round_tripped = HardwareVendorFfi::from(hw::HardwareVendor::from(HardwareVendorFfi::Trezor));
        assert_eq!(round_tripped, HardwareVendorFfi::Trezor);
    }

    #[test]
    fn transport_kind_round_trips_through_the_hardware_crate_type() {
        for kind in [HardwareTransportKind::Usb, HardwareTransportKind::Bluetooth, HardwareTransportKind::QrAirGap] {
            assert_eq!(HardwareTransportKind::from(hw::HardwareTransportKind::from(kind)), kind);
        }
    }

    #[test]
    fn device_info_round_trips_through_the_hardware_crate_type() {
        let info = HardwareDeviceInfoFfi {
            id: "trezor-usb-0".to_string(),
            vendor: HardwareVendorFfi::Trezor,
            transport: HardwareTransportKind::Usb,
            model: "Trezor Model T".to_string(),
            label: Some("my trezor".to_string()),
            firmware_version: Some("2.6.0".to_string()),
            needs_firmware_update: false,
        };
        let round_tripped = HardwareDeviceInfoFfi::from(hw::HardwareDeviceInfo::from(info.clone()));
        assert_eq!(round_tripped, info);
    }

    #[test]
    fn input_request_converts_from_the_hardware_crate_type() {
        assert_eq!(
            HardwareInputRequest::from(hw::HardwareInputRequest::Pin { attempt: 2 }),
            HardwareInputRequest::Pin { attempt: 2 }
        );
        assert_eq!(HardwareInputRequest::from(hw::HardwareInputRequest::Passphrase), HardwareInputRequest::Passphrase);
    }

    #[test]
    fn button_request_converts_from_the_hardware_crate_type() {
        assert_eq!(
            HardwareButtonRequest::from(hw::HardwareButtonRequest::Other { description: "custom".to_string() }),
            HardwareButtonRequest::Other { description: "custom".to_string() }
        );
    }
}
