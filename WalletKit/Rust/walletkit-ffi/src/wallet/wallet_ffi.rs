//! `WalletFfi`: a software wallet — a BIP39 mnemonic plus its derived seed.

use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use aes_gcm::{
    aead::{Aead, KeyInit},
    Aes256Gcm, Nonce,
};
use pbkdf2::pbkdf2_hmac;
use rand::{rngs::OsRng, RngCore};
use sha2::Sha256;

use crate::common::{Curve, DerivationPath, MnemonicWordCount, Wordlist};
use crate::errors::WalletKitErrorFfi;
use crate::keys::{ExtendedKeyFfi, MnemonicFfi, SeedFfi};
use crate::wallet::WalletBackup;

const PBKDF2_ITERATIONS: u32 = 210_000;
const SALT_LEN: usize = 16;
const NONCE_LEN: usize = 12;

#[derive(uniffi::Object)]
pub struct WalletFfi {
    mnemonic: Arc<MnemonicFfi>,
    seed: Arc<SeedFfi>,
    has_passphrase: bool,
    created_at: u64,
}

impl std::fmt::Debug for WalletFfi {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("WalletFfi").finish_non_exhaustive()
    }
}

impl WalletFfi {
    fn from_mnemonic(mnemonic: Arc<MnemonicFfi>, passphrase: &str) -> WalletFfi {
        let seed = mnemonic.to_seed(passphrase.to_string());
        WalletFfi {
            mnemonic,
            seed,
            has_passphrase: !passphrase.is_empty(),
            created_at: SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|duration| duration.as_secs())
                .unwrap_or(0),
        }
    }

    fn word_count_from_u32(word_count: u32) -> Result<MnemonicWordCount, WalletKitErrorFfi> {
        match word_count {
            12 => Ok(MnemonicWordCount::Words12),
            15 => Ok(MnemonicWordCount::Words15),
            18 => Ok(MnemonicWordCount::Words18),
            21 => Ok(MnemonicWordCount::Words21),
            24 => Ok(MnemonicWordCount::Words24),
            other => Err(WalletKitErrorFfi::UnsupportedWordCount { count: other }),
        }
    }

    fn derive_backup_key(password: &str, salt: &[u8]) -> [u8; 32] {
        let mut key = [0u8; 32];
        pbkdf2_hmac::<Sha256>(password.as_bytes(), salt, PBKDF2_ITERATIONS, &mut key);
        key
    }
}

#[uniffi::export]
impl WalletFfi {
    /// Generates a new wallet with a freshly-generated mnemonic.
    /// `word_count` must be one of BIP39's 12/15/18/21/24.
    #[uniffi::constructor]
    pub fn create(word_count: u32, passphrase: String) -> Result<WalletFfi, WalletKitErrorFfi> {
        let word_count = Self::word_count_from_u32(word_count)?;
        let mnemonic = MnemonicFfi::generate(word_count, Wordlist::English);
        Ok(Self::from_mnemonic(Arc::new(mnemonic), &passphrase))
    }

    /// Restores a wallet from an existing BIP39 phrase. Fails with
    /// `InvalidMnemonic` on a bad checksum/word.
    #[uniffi::constructor]
    pub fn restore(phrase: String, passphrase: String) -> Result<WalletFfi, WalletKitErrorFfi> {
        let mnemonic = MnemonicFfi::from_phrase(phrase, Wordlist::English)?;
        Ok(Self::from_mnemonic(Arc::new(mnemonic), &passphrase))
    }

    /// Decrypts a blob produced by `export_encrypted_backup`. Fails with
    /// `DecryptionFailed` on a wrong password or corrupt blob.
    #[uniffi::constructor]
    pub fn restore_encrypted(data: Vec<u8>, password: String) -> Result<WalletFfi, WalletKitErrorFfi> {
        if data.len() < SALT_LEN + NONCE_LEN {
            return Err(WalletKitErrorFfi::DecryptionFailed);
        }
        let (salt, rest) = data.split_at(SALT_LEN);
        let (nonce_bytes, ciphertext) = rest.split_at(NONCE_LEN);

        let key = Self::derive_backup_key(&password, salt);
        let cipher =
            Aes256Gcm::new_from_slice(&key).map_err(|_| WalletKitErrorFfi::DecryptionFailed)?;
        let nonce = Nonce::from_slice(nonce_bytes);
        let plaintext = cipher
            .decrypt(nonce, ciphertext)
            .map_err(|_| WalletKitErrorFfi::DecryptionFailed)?;
        let phrase = String::from_utf8(plaintext).map_err(|_| WalletKitErrorFfi::DecryptionFailed)?;

        WalletFfi::restore(phrase, String::new())
    }

    pub fn mnemonic(&self) -> Arc<MnemonicFfi> {
        self.mnemonic.clone()
    }

    /// Raw 64-byte BIP39 seed. Sensitive — treat as short-lived.
    pub fn seed(&self) -> Vec<u8> {
        self.seed.export_raw()
    }

    /// Manual/advanced derivation for callers that need a non-standard
    /// path, or the actual `ExtendedKeyFfi` to sign with.
    pub fn derive(&self, path: DerivationPath, curve: Curve) -> Result<Arc<ExtendedKeyFfi>, WalletKitErrorFfi> {
        self.seed.master_key(curve).derive(path)
    }

    /// Serializes the BIP32 master extended private key ("xprv").
    pub fn master_xprv(&self) -> String {
        self.seed
            .master_key(Curve::Secp256k1)
            .serialized_private()
            .expect("a freshly-derived master key always has a private key")
    }

    /// Serializes the corresponding BIP32 master extended public key
    /// ("xpub").
    pub fn master_xpub(&self) -> String {
        self.seed.master_key(Curve::Secp256k1).serialized_public()
    }

    /// Plaintext backup payload for callers who manage their own encrypted
    /// storage.
    pub fn export_backup(&self) -> WalletBackup {
        WalletBackup {
            phrase: self.mnemonic.phrase(),
            wordlist: self.mnemonic.wordlist(),
            has_passphrase: self.has_passphrase,
            created_at: self.created_at,
        }
    }

    /// Encrypts this wallet's phrase with a password (PBKDF2-HMAC-SHA256
    /// key derivation + AES-256-GCM) into an opaque blob suitable for
    /// storage. The blob layout is `salt || nonce || ciphertext`.
    pub fn export_encrypted_backup(&self, password: String) -> Result<Vec<u8>, WalletKitErrorFfi> {
        let mut salt = [0u8; SALT_LEN];
        let mut nonce_bytes = [0u8; NONCE_LEN];
        OsRng.fill_bytes(&mut salt);
        OsRng.fill_bytes(&mut nonce_bytes);

        let key = Self::derive_backup_key(&password, &salt);
        let cipher = Aes256Gcm::new_from_slice(&key)
            .map_err(|err| WalletKitErrorFfi::InternalError { message: err.to_string() })?;
        let nonce = Nonce::from_slice(&nonce_bytes);
        let ciphertext = cipher
            .encrypt(nonce, self.mnemonic.phrase().as_bytes())
            .map_err(|err| WalletKitErrorFfi::InternalError { message: err.to_string() })?;

        let mut blob = Vec::with_capacity(SALT_LEN + NONCE_LEN + ciphertext.len());
        blob.extend_from_slice(&salt);
        blob.extend_from_slice(&nonce_bytes);
        blob.extend_from_slice(&ciphertext);
        Ok(blob)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_vectors::english_vectors;

    #[test]
    fn restore_matches_official_bip39_vectors() {
        for (entropy_hex, mnemonic, seed_hex, master_xprv) in english_vectors() {
            let wallet = WalletFfi::restore(mnemonic.clone(), "TREZOR".to_string()).unwrap_or_else(|err| {
                panic!("failed to restore vector for entropy {entropy_hex}: {err}")
            });

            assert_eq!(wallet.mnemonic().phrase(), mnemonic, "entropy {entropy_hex}");
            assert_eq!(hex::encode(wallet.seed()), seed_hex, "entropy {entropy_hex}");
            assert_eq!(wallet.master_xprv(), master_xprv, "entropy {entropy_hex}");
        }
    }

    #[test]
    fn create_generates_a_valid_mnemonic_of_the_requested_length() {
        for word_count in [12, 15, 18, 21, 24] {
            let wallet = WalletFfi::create(word_count, String::new()).unwrap();
            assert_eq!(wallet.mnemonic().word_count() as u32, word_count);
            assert_eq!(wallet.mnemonic().phrase().split(' ').count() as u32, word_count);
            // Must round-trip through restore (validates the checksum).
            WalletFfi::restore(wallet.mnemonic().phrase(), String::new()).unwrap();
        }
    }

    #[test]
    fn create_rejects_an_unsupported_word_count() {
        let err = WalletFfi::create(13, String::new()).unwrap_err();
        assert!(matches!(err, WalletKitErrorFfi::UnsupportedWordCount { count: 13 }));
    }

    #[test]
    fn restore_rejects_an_invalid_phrase() {
        let err = WalletFfi::restore("definitely not a bip39 phrase".to_string(), String::new()).unwrap_err();
        assert!(matches!(err, WalletKitErrorFfi::InvalidMnemonic { .. }));
    }

    #[test]
    fn encrypted_backup_round_trips_with_the_correct_password() {
        let wallet = WalletFfi::create(24, String::new()).unwrap();
        let blob = wallet.export_encrypted_backup("correct-password".to_string()).unwrap();
        let restored = WalletFfi::restore_encrypted(blob, "correct-password".to_string()).unwrap();
        assert_eq!(restored.mnemonic().phrase(), wallet.mnemonic().phrase());
    }

    #[test]
    fn encrypted_backup_fails_with_the_wrong_password() {
        let wallet = WalletFfi::create(24, String::new()).unwrap();
        let blob = wallet.export_encrypted_backup("correct-password".to_string()).unwrap();
        let err = WalletFfi::restore_encrypted(blob, "wrong-password".to_string()).unwrap_err();
        assert!(matches!(err, WalletKitErrorFfi::DecryptionFailed));
    }

    #[test]
    fn export_backup_carries_the_wallets_mnemonic_and_wordlist() {
        let wallet = WalletFfi::create(12, String::new()).unwrap();
        let backup = wallet.export_backup();
        assert_eq!(backup.phrase, wallet.mnemonic().phrase());
        assert_eq!(backup.wordlist, wallet.mnemonic().wordlist());
        assert!(!backup.has_passphrase);
    }
}
