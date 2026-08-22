use async_trait::async_trait;

use crate::{error::HardwareError, info::HardwareDeviceInfo, path::HardwarePathSegment};

/// The elliptic curve to derive a hardware-sourced public key under.
/// Mirrors `walletkit-ffi`'s `common::Curve` so vendor crates don't need to
/// depend on `walletkit-ffi`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HardwareCurve {
    Secp256k1,
    Ed25519,
}

/// The structured fields of an unsigned Ethereum transaction a hardware
/// device's trusted screen needs to display before it signs — the same
/// six semantic fields plus `chainId` `EthereumSignerFfi::decode_signing_data`
/// recovers from EIP-155 RLP. Every integer field is a big-endian byte
/// string with no leading zero byte (empty means zero), matching the wire
/// encoding hardware wallet protocols expect.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EthereumTxFields {
    pub nonce: Vec<u8>,
    pub gas_price: Vec<u8>,
    pub gas_limit: Vec<u8>,
    pub to: Option<Vec<u8>>,
    pub value: Vec<u8>,
    pub data: Vec<u8>,
    pub chain_id: u64,
}

/// An EIP-155 signature, in the shape a hardware device returns it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EthereumSignature {
    pub v: u64,
    pub r: Vec<u8>,
    pub s: Vec<u8>,
}

/// A connected hardware wallet — a source of public keys and signatures,
/// read from / produced by the device rather than derived or computed
/// in-process.
#[async_trait]
pub trait HardwareDevice: Send + Sync {
    /// Static metadata describing this device.
    fn info(&self) -> HardwareDeviceInfo;

    /// Whether this device is still connected.
    fn is_connected(&self) -> bool;

    /// Reads the public key at `path` for `curve` from the device.
    ///
    /// Returns the key's raw bytes (compressed SEC1 for secp256k1); the
    /// caller already knows `curve`, since it supplied it.
    async fn public_key(
        &self,
        path: Vec<HardwarePathSegment>,
        curve: HardwareCurve,
    ) -> Result<Vec<u8>, HardwareError>;

    /// Signs an Ethereum transaction on the device, showing `fields` on
    /// its trusted screen for the user to confirm.
    async fn ethereum_sign_tx(
        &self,
        path: Vec<HardwarePathSegment>,
        fields: EthereumTxFields,
    ) -> Result<EthereumSignature, HardwareError>;

    /// Disconnects from this device.
    async fn disconnect(&self);
}
