//! `EthereumSignerFfi`: address derivation and EIP-155 transaction signing
//! for Ethereum, backed by Alloy's primitives (`alloy-primitives`,
//! `alloy-rlp`) rather than hand-rolled crypto/RLP. See
//! `Walletkit/Docs/Design Specification/Clients/EthereumSigner.swift`.

use std::sync::Arc;

use alloy_primitives::{keccak256, Address as AlloyAddress, Bytes, TxKind, U256};
use alloy_rlp::{Decodable, Encodable, Header};

use crate::blockchain_clients::ethereum_address::EthereumAddressFfi;
use crate::common::Curve;
use crate::errors::WalletKitErrorFfi;
use crate::keys::{PrivateKeyFfi, PublicKeyFfi};

/// EVM chain ID this signer is scoped to (1 = mainnet, 11155111 =
/// Sepolia, ...) — the value carried by `Blockchain.ethereum(_:)`.
#[derive(Debug, Clone, Copy, uniffi::Object)]
pub struct EthereumSignerFfi {
    chain_id: u64,
}

#[uniffi::export]
impl EthereumSignerFfi {
    #[uniffi::constructor]
    pub fn new(chain_id: u64) -> EthereumSignerFfi {
        EthereumSignerFfi { chain_id }
    }

    pub fn chain_id(&self) -> u64 {
        self.chain_id
    }

    /// Derives the `EthereumAddressFfi` for `public_key` — the last 20 bytes
    /// of the Keccak-256 hash of its uncompressed 64-byte (X||Y) public-key
    /// encoding. `public_key.raw_bytes()` is the *compressed* 33-byte SEC1
    /// form; `secp256k1::PublicKey` (and, through it,
    /// `Address::from_secp256k1_public_key`) handles the decompression.
    ///
    /// Throws `.unsupportedCurve` for a non-secp256k1 key — there is no
    /// Ethereum address for an ed25519 key.
    pub fn address(&self, public_key: Arc<PublicKeyFfi>) -> Result<Arc<EthereumAddressFfi>, WalletKitErrorFfi> {
        if public_key.curve() != Curve::Secp256k1 {
            return Err(WalletKitErrorFfi::UnsupportedCurve { curve: public_key.curve() });
        }
        let secp_public_key = secp256k1::PublicKey::from_slice(&public_key.raw_bytes())
            .map_err(|err| WalletKitErrorFfi::InvalidAddress { reason: err.to_string() })?;
        let address = AlloyAddress::from_secp256k1_public_key(&secp_public_key);
        Ok(Arc::new(EthereumAddressFfi::from_alloy(address)))
    }

    /// Signs `signing_data` — the 9-field EIP-155 RLP-encoded
    /// `[nonce, gasPrice, gasLimit, to, value, data, chainId, 0, 0]` unsigned
    /// transaction blob (see `TestVectors/ethereum-tx.json`'s
    /// `signingDataHex`) — with `private_key`, returning the RLP-encoded
    /// signed transaction `[nonce, gasPrice, gasLimit, to, value, data, v, r,
    /// s]` (`signedTxHex`) ready to broadcast.
    ///
    /// `keccak256(signing_data)` *is* the EIP-155 signing hash directly (no
    /// decoding needed for that part); `signing_data` is separately
    /// RLP-decoded to recover the six semantic fields plus `chainId` needed
    /// to re-encode the signed output with `v`/`r`/`s` in place of the
    /// trailing `chainId, 0, 0`.
    ///
    /// Throws `.unsupportedCurve` for a non-secp256k1 key, `.signingFailed`
    /// if `signing_data` isn't well-formed 9-field EIP-155 RLP, its
    /// embedded chain ID doesn't fit in 64 bits, or that chain ID doesn't
    /// match `self.chain_id` — a signer scoped to one network refuses to
    /// silently sign for another.
    pub fn sign(&self, signing_data: Vec<u8>, private_key: Arc<PrivateKeyFfi>) -> Result<Vec<u8>, WalletKitErrorFfi> {
        if private_key.curve() != Curve::Secp256k1 {
            return Err(WalletKitErrorFfi::UnsupportedCurve { curve: private_key.curve() });
        }

        let fields = decode_eip155_signing_fields(&signing_data)?;
        if fields.chain_id != self.chain_id {
            return Err(WalletKitErrorFfi::SigningFailed {
                reason: format!(
                    "signing data's chain id {} does not match signer's configured chain id {}",
                    fields.chain_id, self.chain_id
                ),
            });
        }

        let digest = keccak256(&signing_data);
        let signature = private_key.sign_prehashed_recoverable(digest.0.to_vec())?;
        if signature.compact.len() != 64 {
            return Err(WalletKitErrorFfi::SigningFailed {
                reason: format!("expected a 64-byte compact signature, got {}", signature.compact.len()),
            });
        }
        let r = U256::from_be_slice(&signature.compact[0..32]);
        let s = U256::from_be_slice(&signature.compact[32..64]);
        let v = fields.chain_id * 2 + 35 + u64::from(signature.recovery_id);

        Ok(encode_signed_transaction(&fields, v, r, s))
    }
}

/// The six semantic fields plus `chainId` recovered from decoding a 9-field
/// EIP-155 "signing data" RLP blob.
struct SigningFields {
    nonce: U256,
    gas_price: U256,
    gas_limit: U256,
    to: TxKind,
    value: U256,
    data: Bytes,
    chain_id: u64,
}

fn decode_eip155_signing_fields(signing_data: &[u8]) -> Result<SigningFields, WalletKitErrorFfi> {
    let rlp_error = |err: alloy_rlp::Error| WalletKitErrorFfi::SigningFailed {
        reason: format!("failed to decode EIP-155 signing data: {err}"),
    };

    let mut buf = signing_data;
    let header = Header::decode(&mut buf).map_err(rlp_error)?;
    if !header.list {
        return Err(WalletKitErrorFfi::SigningFailed {
            reason: "expected a 9-field RLP list for EIP-155 signing data".to_string(),
        });
    }

    let nonce = U256::decode(&mut buf).map_err(rlp_error)?;
    let gas_price = U256::decode(&mut buf).map_err(rlp_error)?;
    let gas_limit = U256::decode(&mut buf).map_err(rlp_error)?;
    let to = TxKind::decode(&mut buf).map_err(rlp_error)?;
    let value = U256::decode(&mut buf).map_err(rlp_error)?;
    let data = Bytes::decode(&mut buf).map_err(rlp_error)?;
    let chain_id_u256 = U256::decode(&mut buf).map_err(rlp_error)?;
    let _r_placeholder = U256::decode(&mut buf).map_err(rlp_error)?;
    let _s_placeholder = U256::decode(&mut buf).map_err(rlp_error)?;

    let chain_id: u64 = chain_id_u256.try_into().map_err(|_| WalletKitErrorFfi::SigningFailed {
        reason: "chainId does not fit in 64 bits".to_string(),
    })?;

    Ok(SigningFields { nonce, gas_price, gas_limit, to, value, data, chain_id })
}

fn encode_signed_transaction(fields: &SigningFields, v: u64, r: U256, s: U256) -> Vec<u8> {
    let payload_length = fields.nonce.length()
        + fields.gas_price.length()
        + fields.gas_limit.length()
        + fields.to.length()
        + fields.value.length()
        + fields.data.length()
        + v.length()
        + r.length()
        + s.length();

    let mut out = Vec::new();
    Header { list: true, payload_length }.encode(&mut out);
    fields.nonce.encode(&mut out);
    fields.gas_price.encode(&mut out);
    fields.gas_limit.encode(&mut out);
    fields.to.encode(&mut out);
    fields.value.encode(&mut out);
    fields.data.encode(&mut out);
    v.encode(&mut out);
    r.encode(&mut out);
    s.encode(&mut out);
    out
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use crate::common::Curve;
    use crate::keys::PrivateKeyFfi;

    use super::*;

    struct Vector {
        label: String,
        private_key: Vec<u8>,
        chain_id: u64,
        signing_data: Vec<u8>,
        address: String,
        signed_tx: Vec<u8>,
    }

    fn vectors() -> Vec<Vector> {
        let raw = include_str!("../../../../TestVectors/ethereum-tx.json");
        let json: serde_json::Value = serde_json::from_str(raw).expect("ethereum-tx.json is valid JSON");
        json.as_array()
            .expect("ethereum-tx.json is a JSON array")
            .iter()
            .map(|entry| Vector {
                label: entry["label"].as_str().unwrap().to_string(),
                private_key: hex::decode(entry["privateKey"].as_str().unwrap().trim_start_matches("0x")).unwrap(),
                chain_id: entry["chainId"].as_u64().unwrap(),
                signing_data: hex::decode(entry["signingDataHex"].as_str().unwrap().trim_start_matches("0x"))
                    .unwrap(),
                address: entry["address"].as_str().unwrap().to_string(),
                signed_tx: hex::decode(entry["signedTxHex"].as_str().unwrap().trim_start_matches("0x")).unwrap(),
            })
            .collect()
    }

    fn private_key_from_bytes(raw: &[u8]) -> Arc<PrivateKeyFfi> {
        let array: [u8; 32] = raw.try_into().expect("test vector private keys are 32 bytes");
        Arc::new(PrivateKeyFfi::new(Curve::Secp256k1, array))
    }

    #[test]
    fn address_matches_every_vectors_expected_address() {
        for vector in vectors() {
            let signer = EthereumSignerFfi::new(vector.chain_id);
            let private_key = private_key_from_bytes(&vector.private_key);
            let address = signer.address(private_key.public_key()).unwrap_or_else(|err| panic!("{}: {err}", vector.label));
            assert_eq!(address.string(), vector.address, "{}", vector.label);
        }
    }

    #[test]
    fn sign_matches_every_vectors_expected_signed_transaction() {
        for vector in vectors() {
            let signer = EthereumSignerFfi::new(vector.chain_id);
            let private_key = private_key_from_bytes(&vector.private_key);
            let signed = signer
                .sign(vector.signing_data.clone(), private_key)
                .unwrap_or_else(|err| panic!("{}: {err}", vector.label));
            assert_eq!(signed, vector.signed_tx, "{}", vector.label);
        }
    }

    #[test]
    fn chain_id_returns_the_configured_value() {
        assert_eq!(EthereumSignerFfi::new(11_155_111).chain_id(), 11_155_111);
    }

    #[test]
    fn address_rejects_an_ed25519_key() {
        let signer = EthereumSignerFfi::new(1);
        let private_key = Arc::new(PrivateKeyFfi::new(Curve::Ed25519, [7u8; 32]));
        assert!(matches!(
            signer.address(private_key.public_key()),
            Err(WalletKitErrorFfi::UnsupportedCurve { curve: Curve::Ed25519 })
        ));
    }

    #[test]
    fn sign_rejects_an_ed25519_key() {
        let signer = EthereumSignerFfi::new(1);
        let private_key = Arc::new(PrivateKeyFfi::new(Curve::Ed25519, [7u8; 32]));
        assert!(matches!(
            signer.sign(vec![0xc0], private_key),
            Err(WalletKitErrorFfi::UnsupportedCurve { curve: Curve::Ed25519 })
        ));
    }

    #[test]
    fn sign_rejects_malformed_signing_data() {
        let signer = EthereumSignerFfi::new(1);
        let private_key = private_key_from_bytes(&vectors()[0].private_key);
        assert!(matches!(signer.sign(vec![0xff], private_key), Err(WalletKitErrorFfi::SigningFailed { .. })));
    }

    #[test]
    fn sign_rejects_a_chain_id_mismatch() {
        let vector = &vectors()[0];
        // Vector 0 is mainnet (chain id 1); configure the signer for a
        // different network so it must refuse to sign.
        let signer = EthereumSignerFfi::new(vector.chain_id + 1);
        let private_key = private_key_from_bytes(&vector.private_key);
        assert!(matches!(
            signer.sign(vector.signing_data.clone(), private_key),
            Err(WalletKitErrorFfi::SigningFailed { .. })
        ));
    }
}
