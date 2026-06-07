# MetaMask Delegation Framework — vendored snapshot

| Field | Value |
|---|---|
| Upstream repo | https://github.com/MetaMask/delegation-framework |
| Tag | `v1.3.0` |
| Commit hash | `bfbdf9795a976833ed2fa000baf42fbb83958b03` |
| Fetched on | 2026-06-05 |
| Deployment | Per-chain `DelegationManager` addresses are published in upstream docs/releases; this repo is the source-of-truth contracts (audited by MetaMask) used by ERC-7710 / ERC-7715 toolkits. We deploy locally in Foundry for H5 (no mainnet fork, project rule). |
| Provenance check | `bash casestudy/verify-pins.sh` — confirms this tag→commit and that `src/DelegationManager.sol` + `src/enforcers/NativeTokenTransferAmountEnforcer.sol` are byte-identical (SHA-256) to upstream at the pin |

## Build profile (their settings — do NOT merge into our default profile)

Inherits `casestudy/metamask/foundry.toml`. Our root `foundry.toml` is untouched (project rule #1).

## Submodule pins captured at vendor time

```
8179e08cac72072bd260796633fec41fdfd5b441 lib/FCL
d9bb3b0fc6b737af2c70dab246cabbc7d05afc3c lib/FreshCryptoLib
6c3d762d335d02781bc99e7af9d530613c396f75 lib/SCL
7af70c8993a6f42973f520ae0752386a5032abe7 lib/account-abstraction
16138d1afd4e9711f6c1425133538837bd7787b5 lib/erc7579-implementation
ae570fec082bfe1c1f45b0acca4a2b4f84d345ce lib/forge-std
105fa4e1b0832a6a40cb7ba6e545bb844f02a711 lib/openzeppelin-contracts
6458fb2780a3092bc756e737f246be1de6d3d362 lib/solidity-bytes-utils
4b2fcc43fa0426e19ce88b1f1ec16f5903a2e461 lib/solidity-stringutils
```

## Re-fetching deps

`lib/` is gitignored at our outer repo level. To rebuild from scratch:

```sh
cd casestudy/metamask
git init -q
git submodule update --init --recursive
forge build
```

The pinned commit hashes above must match what `git submodule status` reports.
