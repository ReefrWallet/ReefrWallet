//! Software wallet facade: BIP39 mnemonic generation/restore, BIP32/SLIP-10
//! master key derivation, and password-based encrypted backup. See
//! `Walletkit/Docs/Design Specification/Wallet/` for the target Swift
//! shape (`Wallet`, `WalletBackup`) — `account(_:)` is implemented on the
//! Swift side atop `derive`, since it's plain composition with no
//! cryptography of its own.

mod wallet_backup;
mod wallet_ffi;

pub use wallet_backup::WalletBackup;
pub use wallet_ffi::WalletFfi;
