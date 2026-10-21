#!/bin/sh
# Usage: make_web3icons.sh
# Builds Resources/Networks.xcassets and Resources/Tokens.xcassets from @web3icons/core
# (version pinned in web3icons/package.json). Browse ids/symbols at https://web3icons.io

set -e

# <network-id>[=<name>] -> "<name>Network16" (magenta template)
export NETWORKS="
aptos
arbitrum-one=arbitrum
avalanche
base
binance-smart-chain=bsc
bitcoin
cardano
ethereum
hyper-evm=hyperEVM
mantle
monad
optimism
polygon
robinhood
solana
sui
tron
unichain
"

# <SYMBOL>[=network:<network-id>] -> "<symbol>Token16" (color, circular)
# `network:` takes the network's icon when the token has none.
export TOKENS="
ADA
APT
ARB
AVAX
BASE=network:base
BNB
BTC
ETH
HOOD=network:robinhood
HYPE=network:hyper-evm
MNT
MON=network:monad
OP
POL
SOL
SUI
TRX
UNI
USDC
USDT
"

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

cd "$SCRIPT_DIR/web3icons"
npm ci --silent --ignore-scripts --no-audit --no-fund
node build.mjs "$SCRIPT_DIR/../Resources"
