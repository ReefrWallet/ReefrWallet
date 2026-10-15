<div align="center">

# [![logo](https://reefr.xyz/app-icon.png)<br/>Reefr Wallet](https://reefr.xyz)

### A friendly multi-chain crypto wallet for Mac.

</div>

[![Wallet CI](https://github.com/ReefrWallet/ReefrWallet/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/ReefrWallet/ReefrWallet/actions/workflows/ci.yml)

Swift multi-chain crypto wallet app for macOS, built on top of [WalletKit](https://github.com/ReefrWallet/WalletKit) for key management and blockchain access.

## Building

Requires [mise](https://mise.jdx.dev) and [Tuist](https://tuist.dev) as well as Rust toolkit and [WalletKit dependencies](https://github.com/ReefrWallet/WalletKit#requirements).

```sh
make workspace  # generate ReefrWallet.xcworkspace
```

Then open `ReefrWallet.xcworkspace` in Xcode to build and run the app.
