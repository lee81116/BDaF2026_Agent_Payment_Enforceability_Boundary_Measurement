# Section H — Case Study (locked targets)

**Status**: H0 + H1 complete (vendoring done; mapping & gas annotation pending).
**Date opened**: 2026-06-05.
**Scope reference**: `docs/case-study-impl-plan.md` (H0–H8); candidate survey in `docs/case-study-candidates.md`.

> This file is the **locked** writeup. The pre-selection survey lives in `case-study-candidates.md` and is not edited from here on.

---

## H.1 — Locked targets

Each row below is the contract / source we will actually read and map into our E1/E2/E3 × r_rev/r_scope/r_conf grid. Pinning is enforced by `casestudy/<system>/VERSION.md`; treat any commit drift as a methodology violation.

### Target 1 — Coinbase Spend Permissions (primary; lowest risk, gas-comparable)

| Field | Value |
|---|---|
| System | Coinbase Spend Permissions (modular owner on Coinbase Smart Wallet v1) |
| Upstream repo | https://github.com/coinbase/spend-permissions |
| Tag / commit | `v1.0.0` / `54e99c7e73846418c9b5d2b4139c17d415a27d41` |
| Vendored at | `casestudy/coinbase/` (see `VERSION.md` for submodule pins) |
| On-chain address | `SpendPermissionManager = 0xf85210B21cC50302F477BA56686d2019dC9b67Ad` (Base · Ethereum · Optimism · Arbitrum · Polygon · Zora · BSC · Avalanche) |
| Selected date | 2026-06-05 |
| Reason for selection | Same toolchain as us (Foundry / Solidity), committed `.gas-snapshot` enables H.3 cross-check, audited (Spearbit / Cantina), multi-chain verified deployment, smallest scope-to-read among candidates. Lands squarely on the "enforceable ceiling" side of our thesis (E2 ValueCap + E3 period + r_rev), avoids cross-hop entirely (no redelegation), and ignores r_conf — exactly the pattern we want as a production reference. |

(To be filled in H2 / H3: structural mapping table, "on-chain vs off-chain" lists, gas-annotation table.)

---

### Target 2 — MetaMask Delegation Framework (high-leverage supplement; tests cross-hop r_scope)

| Field | Value |
|---|---|
| System | MetaMask Delegation Framework (ERC-7710 delegation / redelegation + caveat enforcers; ERC-7715 request layer) |
| Upstream repo | https://github.com/MetaMask/delegation-framework |
| Tag / commit | `v1.3.0` / `bfbdf9795a976833ed2fa000baf42fbb83958b03` |
| Vendored at | `casestudy/metamask/` (see `VERSION.md` for submodule pins) |
| On-chain address | Per-chain deployments listed in upstream docs/releases; this repo is the source-of-truth contracts. We deploy **locally** in Foundry (no mainnet fork / RPC, per project rule). |
| Selected date | 2026-06-05 |
| Reason for selection | Only candidate that supports **ERC-7710 redelegation** — the unique system that can answer "does the framework enforce parent caveats along the delegation chain?" (Section G's red square). Caveat-enforcer structure mirrors our `library + harness` factoring, so the E1/E2/E3 mapping is one-to-one; r_rev is supported; r_conf is not addressed (same gap as ours, same finding). |

(To be filled in H4 / H5: enforcer mapping table; cross-hop r_scope test result + evidence level.)

---

## H.2 / H.3 — Coinbase mapping & gas annotation

*Pending.* Will follow `docs/case-study-impl-plan.md` H.2 (mapping) and H.3 (gas annotation against our D/E numbers).

## H.4 / H.5 — MetaMask enforcer mapping & cross-hop r_scope

*Pending.* H.4 fills the 8-module × enforcer correspondence; H.5 attempts a local behavioural test of redelegation chain enforcement and otherwise falls back to source walkthrough with explicit evidence-level labelling.

## H.6 — Comparison synthesis & gradient-table rows

*Pending.*

## H.7 — Aligned / divergent analysis

*Pending.*
