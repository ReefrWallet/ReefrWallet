# Reefr Wallet

[![Wallet CI](https://github.com/kervich/reefr-wallet/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/kervich/reefr-wallet/actions/workflows/ci.yml)

A Swift crypto wallet app for iOS and macOS, built on top of [WalletKit](WalletKit/README.md) for key management and blockchain access.

## Building

Requires [mise](https://mise.jdx.dev) and [Tuist](https://tuist.dev).

```sh
make workspace  # generate ReefrWallet.xcworkspace
make test       # run the Rust and Swift test suites
```

Open `ReefrWallet.xcworkspace` in Xcode to build and run the app.
