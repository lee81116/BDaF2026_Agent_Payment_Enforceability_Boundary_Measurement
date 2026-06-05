# Coinbase Spend Permissions — vendored snapshot

| Field | Value |
|---|---|
| Upstream repo | https://github.com/coinbase/spend-permissions |
| Tag | `v1.0.0` |
| Commit hash | `54e99c7e73846418c9b5d2b4139c17d415a27d41` |
| Fetched on | 2026-06-05 |
| Mainnet deployment | `SpendPermissionManager = 0xf85210B21cC50302F477BA56686d2019dC9b67Ad` (Base · Ethereum · Optimism · Arbitrum · Polygon · Zora · BSC · Avalanche) |
| Audits referenced | Spearbit / Cantina (2024-10, 2024-11, 2024-12); see upstream `docs/audits` |

## Build profile (their settings — do NOT merge into our default profile)

Inherits `casestudy/coinbase/foundry.toml` (optimizer / IR / evm settings are theirs). Our root `foundry.toml` is untouched (project rule #1).

| Field | Value | Source |
|---|---|---|
| `solc_version` | `0.8.35` | local patch (see "Local patch applied at vendor time" below); upstream auto-detects |
| `evm_version` | `cancun` | upstream |
| `optimizer` | upstream default | upstream |
| forge | `1.7.1` | host toolchain |

Recorded H3 callee-frame numbers (`casestudy/coinbase/test/h3-gas/`) were captured under that exact pin and are now asserted at `±2` gas (see `docs/case-study-coinbase.md` §H3.0).

## Submodule pins captured at vendor time

```
fa61290d37d079e928d92d53a122efcc63822214 lib/account-abstraction
58d30519826c313ce47345abedfdc07679e944d1 lib/forge-std
4ce54f16c53c8031d2168a1b7c3e83648a323019 lib/magic-spend         (branch caret-0.8.23)
1edc2ae004974ebf053f4eba26b45469937b9381 lib/openzeppelin-contracts
1bc2d0aa3b7dc6f73bf2029c848cfb88c1104901 lib/smart-wallet         (branch caret-0.8.23)
d87a6baaea980b54f6d0f2d3a3c30c45a5b1520a lib/solady
619f20ab0f074fef41066ee4ab24849a913263b2 lib/webauthn-sol         (tag v1.0.0)
```

## Local patch applied at vendor time

1. `.gitmodules`: rewrote the `lib/magic-spend` URL from `https://github.com/coinbase/magic-spend` to `https://github.com/coinbase/MagicSpend`. Upstream renamed the repo (the old URL now returns "Repository not found"); the new URL serves the same commit and the same `caret-0.8.23` branch.
2. `foundry.toml`: added `solc_version = "0.8.35"` under `[profile.default]`. Upstream auto-detects the compiler from each file's pragma (currently resolves to 0.8.35); we pin the version the recorded H3 numbers were measured under so a future solc release does not silently move them.

## Re-fetching deps

`lib/` is gitignored at our outer repo level. To rebuild from scratch:

```sh
cd casestudy/coinbase
git init -q
git submodule update --init --recursive
forge build
```

The pinned commit hashes above must match what `git submodule status` reports.
