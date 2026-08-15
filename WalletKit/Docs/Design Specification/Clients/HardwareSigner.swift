//
//  HardwareSigner.swift
//  WalletKit
//
//  DESIGN SPEC — not generated code. See Walletkit/Docs/Overview.md for
//  module-level notes and architecture.
//

/// Placeholder for the vendor-aware signing adapter each (chain, hardware
/// vendor) pairing will need once hardware signing ships — e.g. a Trezor
/// Ethereum signer speaks `EthereumSignTx`, a Trezor Bitcoin signer speaks
/// `SignTx`; they are not interchangeable. Not implemented yet; included
/// so the seam is visible before the first chain module is built.
///
/// Sits one level below `BlockchainClient.sign(transaction:account:)`:
/// callers use the `BlockchainClient` method as the one shared entry point
/// regardless of `account.source`, and a hardware-backed conformer routes
/// through its chain's `HardwareSigner` internally once it needs to
/// talk to the device in its native, structured wire format.
public protocol HardwareSigner {
    associatedtype UnsignedTransaction
    associatedtype SignedTransaction

    func sign(
        _ transaction: UnsignedTransaction,
        account: Account,
        device: HardwareDevice
    ) async throws -> SignedTransaction
}
