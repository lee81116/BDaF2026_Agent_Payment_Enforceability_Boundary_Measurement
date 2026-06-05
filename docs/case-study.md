# Section H — Case Study (locked targets)

**Status**: H0–H7 complete (vendoring, structural mapping, gas annotation, cross-hop test, gradient rows, writeup); H8 verification recorded at the bottom.
**Date opened**: 2026-06-05.
**Scope reference**: per-system evidence files in `docs/case-study-coinbase.md` and `docs/case-study-metamask.md`.

> This file is the **locked** synthesis writeup. The per-system files are the evidence dossiers (every `file:line` and every measured number lives there). This page is what someone would read first; it should be defensible on its own.

---

## H.1 — Locked targets

Each row below is the contract / source we read and map into our E1/E2/E3 × r_rev/r_scope/r_conf grid. Pinning is enforced by `casestudy/<system>/VERSION.md`; treat any commit drift as a methodology violation.

### Target 1 — Coinbase Spend Permissions (primary; lowest risk, gas-comparable)

| Field | Value |
|---|---|
| System | Coinbase Spend Permissions (modular owner on Coinbase Smart Wallet v1) |
| Upstream repo | https://github.com/coinbase/spend-permissions |
| Tag / commit | `v1.0.0` / `54e99c7e73846418c9b5d2b4139c17d415a27d41` |
| Vendored at | `casestudy/coinbase/` (see `VERSION.md` for submodule pins) |
| On-chain address | `SpendPermissionManager = 0xf85210B21cC50302F477BA56686d2019dC9b67Ad` (Base · Ethereum · Optimism · Arbitrum · Polygon · Zora · BSC · Avalanche) |
| Selected date | 2026-06-05 |
| Reason for selection | Same toolchain as us (Foundry / Solidity), committed `.gas-snapshot` enables H.3 cross-check, audited (Spearbit / Cantina), multi-chain verified deployment, smallest scope-to-read among candidates. Lands squarely on the "enforceable ceiling" side of our thesis (E2 + E3 + r_rev), avoids cross-hop entirely (no redelegation), and ignores r_conf — exactly the pattern we want as a production reference. |

### Target 2 — MetaMask Delegation Framework (high-leverage supplement; tests cross-hop r_scope)

| Field | Value |
|---|---|
| System | MetaMask Delegation Framework (ERC-7710 delegation / redelegation + caveat enforcers; ERC-7715 request layer) |
| Upstream repo | https://github.com/MetaMask/delegation-framework |
| Tag / commit | `v1.3.0` / `bfbdf9795a976833ed2fa000baf42fbb83958b03` |
| Vendored at | `casestudy/metamask/` (see `VERSION.md` for submodule pins) |
| On-chain address | Per-chain deployments listed upstream; the repo is the source-of-truth contracts. We deploy **locally** in Foundry (no fork / RPC, per project rule). |
| Selected date | 2026-06-05 |
| Reason for selection | Only candidate that supports **ERC-7710 redelegation** — the unique system that can answer "does the framework enforce parent caveats along the delegation chain?" (Section G's red square). Caveat-enforcer structure mirrors our `library + harness` factoring, so the E1/E2/E3 mapping is one-to-one; r_rev is supported; r_conf is not addressed (same gap as ours, same finding). |

---

## H.2 — Coinbase structural mapping (summary)

Full per-cell evidence with file:line refs: `docs/case-study-coinbase.md` §H2. Highlights:

| Axis | Coinbase mechanism | Code reference (`casestudy/coinbase/src/SpendPermissionManager.sol`) |
|---|---|---|
| **E1** access | No arbitrary-call surface. `spend()` accepts only `(SpendPermission, uint160 value)`; `_transferFrom` hard-codes native vs ERC-20 branches; `_approve` rejects ERC-721. | `:106, 420–426, 635–639, 730–753` |
| **E2** transaction-level amount | Cumulative check `totalSpend > allowance` (where `totalSpend = value + currentPeriod.spend`). | `:37, 698–706` |
| **E3** contextual / stateful | `_lastUpdatedPeriod[hash]` packs `PeriodSpend{start48, end48, spend160}` in one slot; `getCurrentPeriod` re-derives the active window and `_useSpendPermission` writes the updated struct (one SSTORE). | `:82–89, 121, 504–553, 711–712` |
| **r_rev** | Two entry points (`revoke`, `revokeAsSpender`) → `_revoke` sets `_isRevoked[hash] = true`. Checked on every spend via `isValid` (`:494–497`). | `:397–411, 494–497, 675–684, 695` |
| **r_scope** single-hop | `requireSender(spender)` + token-scope via `spendPermission.token`. **No redelegation primitive** — spender cannot grant a derived permission. | `:277, 293, 367, 397, 406, 420–426` |
| **r_conf** | Nine struct fields; eight are syntactic. `extraData` is "Arbitrary data … which may be consumed by the spender", **hashed into `getHash` but never validated on-chain**. | `:47, 561–578` |

**One-sentence defence of "what layer this lands at":** Coinbase enforces the **E2 amount × E3 stateful window** ceiling with single-hop scope (r_scope) and explicit revocation (r_rev), and intentionally **does not** address cross-hop r_scope (no redelegation primitive) or r_conf. Production confirmation of the host thesis — chain enforces the *ceiling* of R(P).

---

## H.3 — Coinbase gas annotation (anchored to host D/E)

Full opcode breakdown + residual accounting: `docs/case-study-coinbase.md` §H3. Key numbers:

> **Two number sources never merged.** Coinbase's committed `.gas-snapshot` is `forge --gas-report`-style (whole-test gas, fuzz mean, ~200k for `test_spend_success_ether`). Our `casestudy/coinbase/test/h3-gas/SpendGasMeasureH3.t.sol` uses `vm.lastCallGas().gasTotalUsed` (callee-frame only), matching host Section D methodology. The host `foundry.toml` is **never** modified.

| Coinbase callee-frame (our test) | Storage regime | Coinbase gas | Host D analog | Host gas |
|---|---|---:|---|---:|
| `spend()` native, first ever | ① SSTORE SET (`_lastUpdatedPeriod` zero → non-zero) | **64,821** | `E3_CumulativeDailyCap` R+W ① | 23,000 |
| `spend()` native, cross-tx 2nd | ② SSTORE RESET (non-zero → non-zero) | **46,537** | `E3_CumulativeDailyCap` R+W ② | 5,900 |
| `spend()` native, same-tx 2nd | ③ dirty SSTORE | **33,237** | `E3_CumulativeDailyCap` R+W ③ | 1,100 |
| `revoke()` by account | SSTORE SET (`_isRevoked` zero → non-zero) | **33,545** | (SSTORE SET class) | ~23,000 |

Where the extra ~34k comes from (regime ①): `spend()` is not monolithic. It does `account.execute(SPM, value, "")` → `SPM.receive()` → `safeTransferETH(spender, value)` — three external calls plus value transfers plus `_expectedReceiveAmount` transient-storage flag. Once we strip that AA-infrastructure cost, the residual (~31k) reconciles to within ~15% of summing the matching host D rows. **Policy logic is as cheap as our minimal Escrow**; the premium is for going through ERC-4337/smart-wallet infrastructure.

---

## H.4 — MetaMask enforcer mapping (summary)

Full table with all 19 enforcers and code refs: `docs/case-study-metamask.md` §H4. Highlights for our 8 host modules:

| Host module | MetaMask enforcer (closest) | Code reference (`casestudy/metamask/src/enforcers/`) |
|---|---|---|
| `E1_TargetAllowlist` | `AllowedTargetsEnforcer` | `AllowedTargetsEnforcer.sol:26–51` |
| `E1_SelectorAllowlist` | `AllowedMethodsEnforcer` | `AllowedMethodsEnforcer.sol:27–84` |
| `E2_ValueCap` | `ValueLteEnforcer` | `ValueLteEnforcer.sol:25–43` |
| `E2_TokenAmountCap` | `ERC20TransferAmountEnforcer` / `NativeTokenTransferAmountEnforcer` (cumulative, not per-call) | `ERC20TransferAmountEnforcer.sol:96–97`; `NativeTokenTransferAmountEnforcer.sol:56–57` |
| `E2_ApprovalCap` | (no exact analog — compose `AllowedMethods(approve.selector)` + `AllowedCalldata`) | — |
| `E3_Expiry` | `TimestampEnforcer` and `BlockNumberEnforcer` | `TimestampEnforcer.sol:22–46`; `BlockNumberEnforcer.sol:22–46` |
| `E3_Revocation` | `DelegationManager.disableDelegation` (centralised on the manager, not in an enforcer) | `src/DelegationManager.sol:90–95, 186–188` |
| `E3_CumulativeDailyCap` | `NativeTokenPeriodTransferEnforcer` / `ERC20PeriodTransferEnforcer` / `MultiTokenPeriodEnforcer` | `NativeTokenPeriodTransferEnforcer.sol:34`; `ERC20PeriodTransferEnforcer.sol:35` |

**MetaMask extras we do not model**: streaming (`NativeToken/ERC20StreamingEnforcer`), `NonceEnforcer`, `LimitedCallsEnforcer`, four balance-change enforcers, `NativeTokenPaymentEnforcer`, calldata-pinning family, `RedeemerEnforcer`.
**Host extras MetaMask folds elsewhere**: stateless per-call `E2_ApprovalCap` as a single module; discrete `E3_Revocation` as a policy module (MetaMask centralises this in the manager).

The *shape* of restriction is the same in both systems: each enforcer is a small, single-purpose contract that reverts on disallowed execution. The load-bearing architectural difference is **where state lives** — MetaMask keys state by `(DelegationManager, delegationHash)`; our host keys state by `(Escrow, policyId)`. That fact decides H.5.

---

## H.5 — MetaMask cross-hop r_scope (the high-leverage question)

Full source walk + tests: `docs/case-study-metamask.md` §H5. The single question: **does redelegation enforce parent caveats along the chain, or only the leaf?**

**Source walk (evidence: read).** `DelegationManager.redeemDelegations` (`casestudy/metamask/src/DelegationManager.sol:126–309`) iterates the full chain in four phases:

| Phase | Code | Iteration |
|---|---|---|
| `beforeAllHook` | `:208–227` | leaf→root, every (delegation, caveat) |
| `beforeHook` | `:234–249` | leaf→root, every (delegation, caveat) |
| execution | `:252–253` | one call against the **root delegator's account** |
| `afterHook` | `:256–271` | root→leaf |
| `afterAllHook` | `:279–294` | root→leaf |

Every caveat on every delegation fires. There is no "only the leaf is checked" branch.

**State key (evidence: read).** Every cumulative-cap enforcer keys state by `(msg.sender, delegationHash)`, and only the DelegationManager ever calls `beforeHook`. Effective key = **delegation hash**. Same hash whether A directly redeems `[User→A]` or B redeems through `[A→B, User→A]` → shared counter.

**Behavioural test (evidence: local pass).** `casestudy/metamask/test/h5-crosshop/CrossHopEnforcement.t.sol`:

| Test | Setup | Result |
|---|---|---|
| `test_crossHop_parentCaveat_blocksOverspend` | A spends 1.5 ether through `[User→A]` (cap 2 ether). B tries 1.0 ether through `[A→B, User→A]` — would total 2.5. | **PASS** — reverts with `"NativeTokenTransferAmountEnforcer:allowance-exceeded"`; counter and pool unchanged. |
| `test_crossHop_sharedCounter_andCost` | A:1.5 + B:0.5 = exactly cap (2.0). Then both A and B attempt one more wei. | **PASS** — first two succeed; both follow-ups revert. **B's 2-layer cross-hop redeem: 63,396 gas** (caller-side `gasleft` — `vm.lastCallGas` not in the forge-std MetaMask pins; not summable with host D rows). |

**Section G reconciliation.** Our `test/delegation/CrossHopEscape.t.sol` escape **does not survive** lifting into the MetaMask framework. The conditions our methodology identified as necessary to close cross-hop ("every link's caveat must see a counter anchored to the root") are satisfied by MetaMask for all cumulative-cap enforcers, at a measured ~63k gas cost for a 2-layer redemption. Stateless enforcers (`ValueLte`, `AllowedTargets/Methods`, `Timestamp`, `BlockNumber`) trivially enforce the parent rule because their check has no state to split.

**What would re-open the escape**: issuing two `User→A` delegations with different `salt` (distinct hashes → distinct counters) — covered as a caveat in `case-study-metamask.md` §H5.6.

---

## H.6 — Gradient table rows + aligned / divergent

### H.6.1 — Qualitative gradient (new rows for the report's gradient table)

Adding two rows to the gradient grid (case-study overlay at `docs/figures/casestudy_mapping.svg`):

| System | E1 access | E2 transaction | E3 contextual | r_rev | r_scope (cross-hop) | r_conf |
|---|---|---|---|---|---|---|
| **Host** (baseline) | ✓ `E1_TargetAllowlist` / `E1_SelectorAllowlist` | ✓ `E2_ValueCap` / `E2_TokenAmountCap` / `E2_ApprovalCap` | ✓ `E3_CumulativeDailyCap` + `E3_Expiry` + `E3_Revocation` | ✓ `E3_Revocation` | ✗ Section G escape (`test/delegation/CrossHopEscape.t.sol`) | ✗ Section F (calldata-identical) |
| **Coinbase Spend Permissions v1.0.0** | △ token-only (no arbitrary call) | ✓ `allowance` (per-call ceiling) | ✓ `period` rollover state | ✓ `revoke` / `revokeAsSpender` | n/a — no redelegation primitive | ✗ `extraData` opaque to contract |
| **MetaMask Delegation FW v1.3.0** | ✓ `AllowedTargets` + `AllowedMethods` (+ richer `AllowedCalldata`) | ✓ `ValueLte` (+ cumulative `TransferAmount` family) | ✓ Period enforcers + `Timestamp` + `BlockNumber` | ✓ `DelegationManager.disableDelegation` | ✓ **chain-walked + hash-keyed state** (H5 PASS) | ✗ no enforcer addresses semantic honesty |

### H.6.2 — Quantitative gradient (gas next to each enforceable cell)

| System | E1 (allowlist) | E2 (per-call cap) | E3 (cumulative cap state) | r_rev (set) | r_scope cross-hop |
|---|---|---|---|---|---|
| **Host** | ~2,557 cold callee-frame (`E1_TargetAllowlist`) | ~284 callee-frame (`E2_ValueCap` pass) | 5,900 RESET / 23,000 SET (`E3_CumulativeDailyCap`) | ~2,297 cold SLOAD check (`E3_Revocation`) | not enforced (Section G) |
| **Coinbase** | n/a (no allowlist mechanism) | comparison ≈ ~284-class (line 704) | SSTORE SET ≈ 22.5k inside 64,821 callee-frame total (the rest is AA chain) | 33,545 callee-frame revoke (~22.5k SET + ~3-5k EIP-712 + ~3k event) | n/a (no redelegation) |
| **MetaMask** | linear scan over calldata list (no SSTORE) — bounded by list length | one `require(value_ <= termsValue_)` per call | hash-keyed SSTORE per delegation (per-period struct) | one SSTORE on `disabledDelegations[hash]` + one SLOAD per redeem | **63,396 gas** caller-side for 2-layer redeem (closes Section G) |

The Coinbase numbers and host D numbers share methodology (`vm.lastCallGas`, callee-frame) and can be component-compared (H.3). The MetaMask 63k number is caller-side `gasleft`-based and must not be summed with the others.

### H.6.3 — Aligned / divergent analysis

**Aligned with our thesis** (each point cites code or measurement):

1. *Both* production systems enforce the **E2 amount + E3 stateful** ceiling. Coinbase via `allowance + period` (`SpendPermissionManager.sol:37, 39, 698–706, 711–712`). MetaMask via the `TransferAmount` and `PeriodTransfer` enforcer families (`NativeTokenTransferAmountEnforcer.sol:56–57`; `NativeTokenPeriodTransferEnforcer.sol:34`).
2. *Both* enforce **r_rev** with a one-bit state change + per-spend check. Coinbase: `_isRevoked[hash]` (`SpendPermissionManager.sol:118, 397–411, 681, 695`). MetaMask: `disabledDelegations[hash]` (`DelegationManager.sol:44, 90–95, 186–188`).
3. *Neither* addresses **r_conf** on-chain. Coinbase ships `extraData` as opaque payload (`SpendPermissionManager.sol:47`). MetaMask has no enforcer for semantic honesty (full survey in `case-study-metamask.md` §H4 — none of 19 enforcers reads counterparty / purpose / identity).
4. The gas cost of the policy *logic* (versus infrastructure) is small in both production systems and within ~15% of our minimal-Escrow baseline (H.3 residual analysis).

**Divergent** (each point cites code or measurement):

1. **Cross-hop r_scope.** Coinbase **sidesteps** by not implementing redelegation (`SpendPermissionManager.sol` has no `delegate` function; spender authority is checked at `:422` but cannot be transitively assigned). MetaMask **enforces** it via chain-walked caveats + hash-keyed state, at measured 63,396 gas for 2 layers (H5 tests). Our `Escrow` is closer to MetaMask in shape (re-delegation is structurally possible) but currently splits state per-delegation (Section G escape). **Take-away**: the production systems frame the cross-hop question two different ways; both are defensible (avoid vs enforce), and we want the latter.
2. **State location.** Coinbase keeps policy state on `SpendPermissionManager` (`:115, 118, 121, 126 transient`). MetaMask keeps it inside each enforcer contract (e.g. `spentMap` on `NativeTokenTransferAmountEnforcer.sol:20`) and revocation on the manager. Our host distributes state across policy libraries + Escrow. **Take-away**: there is no single "right" placement; each placement trades modularity against the cost of an extra SLOAD/SSTORE hop.
3. **AA infrastructure surcharge.** Coinbase pays ~34k per spend for its `account.execute → receive → safeTransferETH` chain (H.3 decomposition). MetaMask pays the analogous cost via `DelegationManager → executeFromExecutor` (`DelegationManager.sol:252–253`). Our `Escrow.settle` is monolithic and skips it — **a real cost difference that is not about policy expressiveness at all**. When reporting "gas for an enforced policy", we must disentangle policy-logic cost from AA-infrastructure cost.
4. **E1 representation.** Coinbase has no allowlist at all (the call shape is restricted to "transfer this one token"; it is *coarser* than our E1). MetaMask's allowlists pass the data inline in `terms` and linear-scan (`AllowedTargetsEnforcer.sol:43–49`), whereas ours SSTORE-stores them (one cold SLOAD, O(1) per check). For small lists the costs are within tens of gas; for large lists ours is constant and MetaMask's grows.
5. **Per-call vs cumulative E2.** MetaMask has no stateless per-call cap (`ValueLteEnforcer` is per-call but only for native value; the ERC-20 amount enforcers always accumulate). Our `E2_ValueCap` / `E2_TokenAmountCap` are stateless (~284 gas). **Take-away**: a stateless per-call cap is a primitive worth shipping as its own module; chaining a cumulative enforcer with `allowance == per-call-cap` is not equivalent (it locks state on every call).

---

## H.7 — Synthesis (oral-defense-ready)

The two case studies are independent confirmations of the host thesis, each from a different angle:

1. **Coinbase Spend Permissions** is a production system that deliberately occupies the "enforceable ceiling" corner of the grid. It enforces what can be enforced on-chain (E2 × E3 × r_rev × single-hop r_scope) and **declines to model** what cannot (r_conf is opaque `extraData`; cross-hop is sidestepped by not offering redelegation). The gas cost of its policy logic is within ~15% of our minimal Escrow's once the irreducible AA-infrastructure cost is stripped — i.e. **production-grade enforceability is not a gas problem at the policy layer**.

2. **MetaMask Delegation Framework** is a production system that explicitly handles the cross-hop question and gives a positive answer for the only enforcement-relevant case: cumulative-cap enforcers share a single counter keyed by `delegationHash`, and `DelegationManager.redeemDelegations` walks the chain so every parent caveat fires. The Section G escape we wrote does not survive being lifted into this framework. The cost of that guarantee — **63,396 gas for a 2-layer redemption** — is the empirical price of cross-hop r_scope.

3. **Both** systems leave **r_conf** to off-chain agreement. There is no surveyed enforcer or struct field in either system that lets the chain decide whether the spender is being honest about *why* the money is moving. Our methodology line — "r_conf requires importing an off-chain truth (oracle / attestation / identity); the chain alone cannot decide it" — is the conclusion both systems reached by *not* trying.

What this lets us claim: **the boundary the host project measures is a real boundary**. Production systems that go further into "enforce more on-chain" either (a) restrict the call surface so the question doesn't arise (Coinbase: no arbitrary call) or (b) pay for chain-walked global state to close compositional gaps (MetaMask: hash-keyed counter + chain walk). Neither path crosses the r_conf wall.

What this does *not* let us claim: that any of these systems are *wrong* for not addressing r_conf. They are correctly observing what is enforceable on-chain. The host thesis is consistent with their design.

---

## H.8 — Verification & acceptance checklist

Recorded at PR time on branch `feat/section-h`:

- [x] **`forge test` (host repo) green.** 78 passed / 0 failed / 0 skipped at every section commit (H0+H1, H2+H3, H4+H5, H6+H7). See commit messages for the corresponding test runs.
- [x] **`foundry.toml` default profile untouched.** `git diff main..feat/section-h -- foundry.toml` is empty. solc 0.8.26 / optimizer 200 / via_ir=false preserved (golden rule #1).
- [x] **`snapshots/` untouched.** `git diff main..feat/section-h -- snapshots/` is empty; `baseline.snap` and `current.snap` are the same numbers as before H started.
- [x] **`src/`, `test/`, `docs/gas-results.md` untouched** by H work.
- [x] **Both case-study sources vendored at pinned commits**, with `VERSION.md` recording repo URL + commit hash + tag + deployed address + fetch date:
  - `casestudy/coinbase/VERSION.md` — `coinbase/spend-permissions` v1.0.0 @ `54e99c7e`, `SpendPermissionManager = 0xf85210B21cC50302F477BA56686d2019dC9b67Ad`.
  - `casestudy/metamask/VERSION.md` — `MetaMask/delegation-framework` v1.3.0 @ `bfbdf979`.
  - One documented local patch: `casestudy/coinbase/.gitmodules` `lib/magic-spend` URL updated (`coinbase/magic-spend` → `coinbase/MagicSpend`; upstream renamed).
- [x] **Coinbase: framework mapping (H2) + gas annotation table (H3) complete.** Detail file: `docs/case-study-coinbase.md`. Test: `casestudy/coinbase/test/h3-gas/SpendGasMeasureH3.t.sol` (4 callee-frame measurements covering the three SSTORE regimes + revoke).
- [x] **MetaMask: enforcer mapping (H4) + cross-hop conclusion (H5, evidence level: local PASS) complete.** Detail file: `docs/case-study-metamask.md`. Test: `casestudy/metamask/test/h5-crosshop/CrossHopEnforcement.t.sol` (2 PASS).
- [x] **Gradient table rows filled (H.6.1 / H.6.2)** with both qualitative and quantitative columns; aligned/divergent analysis (H.6.3) has code-ref or measurement backing on every point.
- [x] **Figures**: new `docs/figures/casestudy_mapping.svg` overlays the three systems on the seven enforceability axes.
- [x] **One commit per section** on `feat/section-h`: `7fbab9f` (H0+H1) → `119abbf` (H2+H3) → `53b58e4` (H4+H5) → this commit (H6+H7+H8).
- [x] **PR `feat/section-h` → `main`** — PR #2.
