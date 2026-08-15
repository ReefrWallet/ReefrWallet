//! `WalletBackup`: plaintext backup payload — the phrase plus enough
//! metadata to restore deterministically.

use crate::common::Wordlist;

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct WalletBackup {
    pub phrase: String,
    pub wordlist: Wordlist,
    pub has_passphrase: bool,
    pub created_at: u64,
}
