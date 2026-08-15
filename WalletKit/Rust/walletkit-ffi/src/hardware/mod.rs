//! Placeholder for vendor-agnostic hardware wallet plumbing. Intentionally
//! empty — see `Walletkit/Docs/Design Specification/Hardware/` for the
//! target shape: `HardwareVendor`, `HardwareTransportKind`,
//! `HardwareDeviceInfo`, `HardwareInputRequest`, `HardwareButtonRequest`,
//! `HardwareDeviceDelegate`, `HardwareDeviceManager`, `HardwareDevice`.
//!
//! Vendor-specific implementations (Trezor first) live in their own
//! crates (`walletkit-trezor`, ...), not here — see
//! `Walletkit/Docs/Overview.md`.
