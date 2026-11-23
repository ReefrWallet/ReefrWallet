# Hyperliquid fixtures

Raw `POST /info` responses for public leaderboard accounts, recorded 2026-11-21 (ADR-074).

- `hyperliquid-<network>-metadata.json`: `perpDexs`, `allPerpMetas`, `spotMetaAndAssetCtxs`, read first.
- `hyperliquid-<case>.json`: one account's `userAbstraction`, `spotClearinghouseState`, `clearinghouseState` by dex, `borrowLendUserState`, `userVaultEquities` and `delegatorSummary`, read right after the metadata. `referenceAccountValue` is the last `day` point of `portfolio`: Hyperliquid's own account value.
- Testnet metadata and dex states are trimmed to the first 3 of 288 perp dexes, and its spot metadata to USDC, HYPE and their pair.
