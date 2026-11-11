<div align="center">

# [Reefr Wallet](https://reefr.xyz)

### Friendly, native, self-custody, multi-chain crypto wallet for macOS and iOS.

<img src="https://reefr.xyz/screenshots/reefr-large.png" alt="Reefr Wallet on Mac and iPhone" width="800">

</div>

[![Wallet CI](https://github.com/ReefrWallet/ReefrWallet/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/ReefrWallet/ReefrWallet/actions/workflows/ci.yml)

Open source under the BSD 3-Clause license. Written in SwiftUI on [WalletKit](https://github.com/ReefrWallet/WalletKit).

[Download](https://github.com/ReefrWallet/ReefrWallet/releases)

## Supported Blockchains

| Network | Trezor | In-app browser APIs | WalletConnect |
| --- | --- | --- | --- |
| Bitcoin | Yes | — | — |
| EVM | Yes | EIP-1193, EIP-6963, Wallet Standard | Yes |
| Solana | Yes | Wallet Standard, `window.solana` | Yes |
| Sui | — | Wallet Standard | Yes |
| Cardano | Yes | CIP-30 | — |
| Tron | Yes | TronLink, TIP-1193, TIP-6963 | Yes |
| Aptos | — | Wallet Standard | Yes |

## Features

- Runs on macOS 15 or later and iOS 18 or later.
- Local keys from BIP-39 recovery phrases or SLIP-39 shares. Stored keys are protected with biometry or password.
- Trezor over USB, on macOS only.
- Watch-only addresses, including ENS names.
- Native staking on Cardano, Solana, Sui and Tron.
- Built-in dapp browser and WalletConnect.
- No account, KYC or Reefr servers. Custom RPC endpoints and optional API keys.

## Building

Requires [mise](https://mise.jdx.dev) and [Tuist](https://github.com/tuist/tuist) as well as Rust toolkit and [WalletKit dependencies](https://github.com/ReefrWallet/WalletKit#requirements).

```sh
make workspace
```

Then open `ReefrWallet.xcworkspace` in Xcode to build and run the app.
