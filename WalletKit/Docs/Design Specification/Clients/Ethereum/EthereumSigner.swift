//
//  EthereumSigner.swift
//  WalletKit
//
//  DESIGN SPEC — not generated code. See Walletkit/Docs/Overview.md for
//  module-level notes and architecture.
//

import Foundation

/// Concrete `Signer` conformer, backed by a dedicated
/// `walletkit-ethereum` Rust crate (see "Crate layout" in Overview.md).
/// Covers address derivation and transaction signing —
/// `sign(transaction:account:)` takes an already-built, RLP-encoded
/// unsigned transaction rather than constructing one itself; gas
/// estimation and RPC access aren't this type's job.
public final class EthereumSigner: Signer {
    public typealias Address = EthereumAddress

    /// EVM chain ID this signer is scoped to (1 = mainnet, 11155111 =
    /// Sepolia, ...) — the value carried by `Blockchain.ethereum(_:)`.
    /// Address derivation doesn't depend on it (see `address(for:)`), but
    /// `sign(transaction:account:)` uses it for EIP-155 replay
    /// protection, so it lives on the signer rather than being threaded
    /// through every call.
    public let chainId: UInt64

    public var blockchain: Blockchain { .ethereum(chainId) }

    /// - Parameter chainId: the EVM network this signer signs
    ///   transactions for. Defaults to `1` (Ethereum mainnet).
    public init(chainId: UInt64 = 1) {
        self.chainId = chainId
    }

    /// Derives the `EthereumAddress` for `account`.
    ///
    /// Algorithm (Keccak-256 — the original Keccak padding, not the
    /// NIST-finalized SHA3-256):
    /// 1. Take the account's uncompressed secp256k1 public key as 64 raw
    ///    bytes (X || Y, no leading `0x04` prefix byte).
    /// 2. Keccak-256 hash those 64 bytes.
    /// 3. The address's raw bytes are the last 20 bytes of that 32-byte
    ///    hash — wrapped via `EthereumAddress(rawBytes:)`, which is always
    ///    exactly 20 bytes here so the throwing initializer never actually
    ///    throws on this path. EIP-55 checksum encoding is computed
    ///    lazily by `EthereumAddress.string`/`.checksummed`, not here.
    ///
    /// Throws `.unsupportedCurve` if `account.curve != .secp256k1` — there
    /// is no Ethereum address for an ed25519-sourced account.
    ///
    /// Open question this spec doesn't resolve: `PublicKey.rawBytes`
    /// exposes the *compressed* 33-byte SEC1 encoding, but step 1 above
    /// needs the *uncompressed* 64-byte X||Y form. `walletkit-ethereum`
    /// will need to either decompress the point itself (recover Y from X
    /// and the compression-flag parity bit) or `walletkit-keys` will need
    /// to grow an uncompressed-form accessor — not decided here.
    ///
    /// Tested against the shared vectors in `TestVectors/ethereum-address.json`
    /// (private key → expected checksummed address); see "Testing strategy"
    /// in Overview.md.
    public func address(for account: Account) throws -> EthereumAddress {
        fatalError("spec only")
    }

    /// Signs an RLP-encoded unsigned Ethereum transaction, returning the
    /// RLP-encoded signed transaction (with the `v`/`r`/`s` signature
    /// fields populated, `v` following EIP-155 replay protection keyed to
    /// `self.chainId`) ready to broadcast.
    ///
    /// Software path: recovers the signing key via `account.derivationPath`
    /// and signs with `PrivateKey.sign(message:)` over the transaction's
    /// Keccak-256 hash. Hardware path: reconstructs the structured
    /// `EthereumSignTx` fields from `transaction` and routes through a
    /// Trezor-specific `HardwareSigner` conformer — see
    /// `Signer.sign(transaction:account:)`'s docs for why that
    /// reconstruction is necessary rather than forwarding the raw bytes.
    ///
    /// Throws `.signingFailed` if `account.blockchain` doesn't match
    /// `self.blockchain` — e.g. an account tagged `.ethereum(1)` used
    /// with a signer configured for `.ethereum(11155111)`. A signer
    /// scoped to one network refuses to silently sign for another.
    ///
    /// Tested against the shared vectors in `TestVectors/ethereum-tx.json`
    /// (unsigned transaction + private key → expected signed transaction);
    /// see "Testing strategy" in Overview.md.
    public func sign(transaction: Data, account: Account) async throws -> Data {
        fatalError("spec only")
    }
}
