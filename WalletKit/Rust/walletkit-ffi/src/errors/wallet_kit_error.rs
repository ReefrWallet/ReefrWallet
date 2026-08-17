//! `WalletKitErrorFfi`. See
//! `Walletkit/Docs/Design Specification/Errors/WalletKitError.swift` for
//! the target shape (a single error enum covering both software
//! key-management and hardware-device failure cases).

use crate::common::Curve;

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum WalletKitErrorFfi {
    #[error("invalid mnemonic: {reason}")]
    InvalidMnemonic { reason: String },
    #[error("invalid entropy")]
    InvalidEntropy,
    #[error("invalid passphrase")]
    InvalidPassphrase,
    #[error("invalid derivation path: {path}")]
    InvalidDerivationPath { path: String },
    #[error("invalid address: {reason}")]
    InvalidAddress { reason: String },
    #[error("unsupported curve: {curve:?}")]
    UnsupportedCurve { curve: Curve },
    #[error("invalid big integer: {reason}")]
    InvalidBigInt { reason: String },
    #[error("unsupported word count: {count}")]
    UnsupportedWordCount { count: u32 },
    #[error("signing failed: {reason}")]
    SigningFailed { reason: String },
    #[error("key not found")]
    KeyNotFound,
    #[error("decryption failed")]
    DecryptionFailed,
    #[error("internal error: {message}")]
    InternalError { message: String },

    // Hardware wallet errors.
    #[error("device not found")]
    DeviceNotFound,
    #[error("device disconnected")]
    DeviceDisconnected,
    #[error("device locked")]
    DeviceLocked,
    #[error("device busy")]
    DeviceBusy,
    #[error("user rejected on device")]
    UserRejectedOnDevice,
    #[error("transport unavailable: {reason}")]
    TransportUnavailable { reason: String },
    #[error("unsupported device: {reason}")]
    UnsupportedDevice { reason: String },
    #[error("firmware outdated: minimum version {minimum_version}")]
    FirmwareOutdated { minimum_version: String },
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn associated_values_are_compared_for_equality() {
        assert_eq!(
            WalletKitErrorFfi::InvalidMnemonic { reason: "bad checksum".to_string() },
            WalletKitErrorFfi::InvalidMnemonic { reason: "bad checksum".to_string() }
        );
        assert_ne!(
            WalletKitErrorFfi::InvalidMnemonic { reason: "a".to_string() },
            WalletKitErrorFfi::InvalidMnemonic { reason: "b".to_string() }
        );
    }

    #[test]
    fn distinct_cases_are_not_equal() {
        assert_ne!(WalletKitErrorFfi::InvalidEntropy, WalletKitErrorFfi::InvalidPassphrase);
    }

    #[test]
    fn invalid_address_carries_its_reason() {
        assert_eq!(
            WalletKitErrorFfi::InvalidAddress { reason: "wrong length".to_string() },
            WalletKitErrorFfi::InvalidAddress { reason: "wrong length".to_string() }
        );
        assert_ne!(
            WalletKitErrorFfi::InvalidAddress { reason: "a".to_string() },
            WalletKitErrorFfi::InvalidDerivationPath { path: "a".to_string() }
        );
    }

    #[test]
    fn hardware_error_cases_construct_with_their_payloads() {
        let cases = [
            WalletKitErrorFfi::DeviceNotFound,
            WalletKitErrorFfi::DeviceDisconnected,
            WalletKitErrorFfi::DeviceLocked,
            WalletKitErrorFfi::DeviceBusy,
            WalletKitErrorFfi::UserRejectedOnDevice,
            WalletKitErrorFfi::TransportUnavailable {
                reason: "usb unavailable on iOS".to_string(),
            },
            WalletKitErrorFfi::UnsupportedDevice {
                reason: "unknown model".to_string(),
            },
            WalletKitErrorFfi::FirmwareOutdated {
                minimum_version: "2.6.0".to_string(),
            },
        ];
        assert_eq!(cases.len(), 8);
    }
}
