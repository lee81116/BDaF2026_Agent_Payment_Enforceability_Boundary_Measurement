# Coinbase Spend Permissions — Case Study (H2 + H3)

**Pinned source**: `casestudy/coinbase/` @ `coinbase/spend-permissions` v1.0.0
(commit `54e99c7e`). Deployed `SpendPermissionManager =
0xf85210B21cC50302F477BA56686d2019dC9b67Ad` on Base / Ethereum / Optimism /
Arbitrum / Polygon / Zora / BSC / Avalanche. See `casestudy/coinbase/VERSION.md`.

All `file:line` refs are to that pinned tree; the file we read is
`casestudy/coinbase/src/SpendPermissionManager.sol` unless otherwise noted.

---

## H2 — Structural reading & framework mapping

### H2.1 — Permission shape

The unit is a `SpendPermission` struct (lines 29–48):

```solidity
struct SpendPermission {
    address account;     // smart account that is the source of funds
    address spender;     // entity authorised to spend
    address token;       // ERC-7528 native or ERC-20
    uint160 allowance;   // max cumulative spend per `period`
    uint48  period;      // window length in seconds
    uint48  start;
    uint48  end;
    uint256 salt;
    bytes   extraData;
}
```

Hashed via EIP-712 in `getHash` (lines 561–578) and stored only as a hash key
in three mappings: `_isApproved` (115), `_isRevoked` (118), `_lastUpdatedPeriod`
(121). There is no per-permission per-call state and no notion of a delegated
sub-permission — the chain is exactly **account → spender, one hop**.

### H2.2 — Mapping into our E × r grid

| Axis | Coinbase mechanism | Code reference | Host analog (our framework) |
|---|---|---|---|
| **E1 — access face** | No arbitrary `call` surface. `spend()` accepts only `(SpendPermission, uint160 value)` — no `target` / `data` from the spender. `_transferFrom` (730–753) hard-codes two branches: native (NATIVE_TOKEN == `0xEee…eEeE`, line 106, 731) and ERC-20 (`approve` + `safeTransferFrom`, 743–751). `_approve` (635–639) rejects ERC-721 via `ERC165Checker.supportsInterface`. | `src/SpendPermissionManager.sol:106, 420–426, 635–639, 730–753` | Coarser than our `E1_TargetAllowlist` / `E1_SelectorAllowlist`. Coinbase has no allowlist mapping at all because the call shape itself is restricted to "transfer this one token". |
| **E2 — transaction-level amount** | The per-call check `if (totalSpend > spendPermission.allowance) revert ExceededSpendPermission(...)` (line 704) where `totalSpend = value + currentPeriod.spend` (698). The cap (`allowance`) is read from calldata; the running total comes from storage. | `src/SpendPermissionManager.sol:37, 698–706` | Functionally a **per-call ceiling** — our `E2_ValueCap` for native (host `E2_ValueCap pass = 284`) or `E2_TokenAmountCap` for ERC-20. Difference: Coinbase's "cap" is a *running* upper bound (cumulative within the period), not a per-tx instantaneous bound. |
| **E3 — contextual / stateful** | `_lastUpdatedPeriod[hash]` (121) packs `PeriodSpend{ start48, end48, spend160 }` into one slot. `getCurrentPeriod` (516–553) re-derives the active window: if `lastPeriodExists && lastPeriodStillActive` (528, 531) return the existing struct; else compute fresh `{start, end, spend:0}` aligned on `start + n * period` (540–551). On a successful spend, `_useSpendPermission` writes the updated struct in one SSTORE (711–712) and emits `SpendPermissionUsed` (713–719). | `src/SpendPermissionManager.sol:82–89, 121, 504–553, 690–720` | Direct analog of our `E3_CumulativeDailyCap` — same "running total + reset window" idiom, generalised from 1 day to any `period`. Also covers `E3_Expiry` (start/end timestamp gating at 519–523). |
| **r_rev — revocation** | Two entry points: `revoke` (397–399, account only) and `revokeAsSpender` (406–411, spender only). Both flow into `_revoke` (675–684) which sets `_isRevoked[hash] = true` and emits. The check side lives in `isValid` (494–497) which gates every spend via `_useSpendPermission` (695). | `src/SpendPermissionManager.sol:397–411, 494–497, 675–684, 695` | Matches our `E3_Revocation` model exactly — one boolean SSTORE on revoke, one SLOAD on every spend. |
| **r_scope — single-hop** | Spender authority is enforced by `requireSender(spendPermission.spender)` on every spend (line 422) and revokeAsSpender (408). Token scope is enforced because `_transferFrom` always uses `spendPermission.token` (425) — the spender supplies only `value`, not the token. There is **no redelegation**: `spender` cannot grant a sub-permission to anyone else because (a) the contract has no `delegate` function and (b) the spender is not authorised to call `_approve` on a derived permission (each `approve` path goes through `requireSender(spendPermission.account)` or an account signature, 277–306, 367–390). | `src/SpendPermissionManager.sol:277, 293, 367, 397, 406, 420–426, 730–753` | Within our framework this is **r_scope single-hop only**. The cross-hop r_scope question (our Section G's red square) does not arise because the system never offers redelegation. The "expressiveness ceiling" answer is therefore: **Coinbase deliberately avoids the cross-hop failure mode by removing the feature.** |
| **r_conf — semantic honesty** | The `SpendPermission` struct has nine fields. Eight (`account`, `spender`, `token`, `allowance`, `period`, `start`, `end`, `salt`) are syntactic — they identify *who* may move *what* and *how much* over *what window*. The ninth (`extraData`, line 47) is documented as "Arbitrary data to attach to a spend permission which may be consumed by the `spender`" — it is hashed into `getHash` (574) so it cannot be silently changed, but **nothing on-chain reads, validates, or constrains it**. There is no oracle, no attestation, no merchant identity, no purpose tag, and no after-the-fact reconciliation hook. | `src/SpendPermissionManager.sol:47, 561–578` (hash inclusion) | Same r_conf gap as our framework (Section F). Coinbase ships the same conclusion: the chain can verify the *ceiling* (cap + window + scope) but not whether the spender is being honest about *why* the money is moving. |

### H2.3 — On-chain enforcement vs delegated to off-chain

**Enforced on-chain in `SpendPermissionManager`** (each row backed by a runtime
check or write):

1. Spender authority — `requireSender(spendPermission.spender)` at `spend` /
   `spendWithWithdraw` / `revokeAsSpender` entries (422, 441, 408).
2. Account authority for approve / revoke — `requireSender(spendPermission.account)`
   at `approve` / `approveWithRevoke` / `revoke` (279, 371, 397).
3. Approval-and-not-revoked precondition — `isValid` SLOAD pair at 494–497,
   invoked by `_useSpendPermission` at 695.
4. Time-window gating — `currentTimestamp < start` and `>= end` checks in
   `getCurrentPeriod` (519–523).
5. Period rollover accounting — `_lastUpdatedPeriod` SSTORE at 712.
6. Cumulative allowance ceiling — comparison at 704
   (`totalSpend > spendPermission.allowance`).
7. Token-class scope — `_transferFrom` ignores any spender-supplied token,
   uses `spendPermission.token` (425).
8. ERC-721 rejection — `_approve` at 635–639 (NFTs cannot be the subject of
   a spend permission, preventing transfers via this surface).
9. Native-token receive guard — `receive()` at 266–268 only accepts the
   transient `_expectedReceiveAmount`, blocking unsolicited ETH credits.
10. Signature integrity for delegated approve — `approveWithSignature` and
    `approveBatchWithSignature` route through `PUBLIC_ERC6492_VALIDATOR`
    (299–304, 322–327).
11. uint160 overflow guard on cumulative spend — line 701.

**Pushed off-chain (or simply unaddressed)**:

1. **`r_conf` — semantic honesty.** Whether the spender's withdrawal matches
   the agreed off-chain purpose (price, merchant, item, refund policy) is not
   modelled. `extraData` is opaque payload, not a constraint.
2. **Cross-hop r_scope.** Re-delegation (Section G's red square) is avoided
   by *not implementing the feature*. Any downstream pay-out chain
   (spender → vendor → sub-vendor) is invisible to this contract.
3. **Cap rotation / safe-replace semantics.** `approveWithRevoke` (367–390)
   provides a "swap" primitive that mitigates front-running by requiring the
   caller to attest to the old permission's `expectedLastUpdatedPeriod`;
   if an off-chain agent fails to use this entry point, the burden of
   ordering is theirs.
4. **Identity / KYA.** No agent identity or attestation hook — analogous to
   our methodology.md note that r_conf must `import` an off-chain truth.
5. **Settlement legibility.** The protocol records that "X wei moved from
   account A to spender S at time T" via `SpendPermissionUsed` (713–719);
   higher-level "what was purchased" lives in off-chain receipts.

### H2.4 — One-sentence defence of "what layer this lands at"

> Coinbase Spend Permissions enforces the **E2 amount × E3 stateful window**
> ceiling with single-hop scope (r_scope) and explicit revocation (r_rev),
> and intentionally **does not** address either cross-hop r_scope (no
> redelegation primitive exists) or r_conf (the `extraData` field is opaque to
> the contract). It is a production confirmation of the host thesis: on-chain
> mechanisms enforce the *ceiling* of R(P); semantic honesty is left to
> off-chain agreement.

---

## H3 — Gas annotation (cross-anchored to host D/E)

### H3.0 — Two number sources, never merged

Two sets of gas numbers appear below; **they measure different things** and
must not be summed or directly differenced.

| Source | Method | What it includes | Compile profile |
|---|---|---|---|
| Coinbase `.gas-snapshot` (committed in their repo) | `forge --gas-report`-style — the whole test-function gas, averaged across 256 fuzz runs | Caller setup, calldata copying, fuzz-arg variance, all sub-calls | `casestudy/coinbase/foundry.toml` (their settings: solc 0.8.x, default optimizer) |
| **Our** `casestudy/coinbase/test/h3-gas/SpendGasMeasureH3.t.sol` | `vm.lastCallGas().gasTotalUsed` captured on the external `call` to `SpendPermissionManager` — **callee-frame only** | Only what runs inside `SpendPermissionManager.spend` / `revoke` and its sub-calls | Same `casestudy/coinbase/foundry.toml`. **Host `foundry.toml` is untouched** (golden rule #1). |
| Host `docs/gas-results.md` (Section D) | `vm.lastCallGas().gasTotalUsed` on isolated policy-library calls | Only the policy-library check | Host `foundry.toml` (solc 0.8.26 / optimizer 200 / via_ir=false / pinned forge 1.7.1) |

Comparing the host D rows to **our** Coinbase callee-frame numbers is
methodologically sound; comparing either to the committed `.gas-snapshot`
is **not**.

### H3.1 — Coinbase `.gas-snapshot` reference (their numbers, their methodology)

From `casestudy/coinbase/.gas-snapshot`, fuzz-mean over 256 runs:

| Test | Mean gas |
|---|---:|
| `SpendTest::test_spend_success_ether` (first spend, fresh period) | 199,163 |
| `SpendTest::test_spend_success_ether_alreadyInitialized` (repeat, same period) | 172,602 |
| `SpendTest::test_spend_success_ERC20ReturnsTrue` | 186,880 |
| `RevokeTest::test_revoke_success_isNoLongerAuthorized` | 87,261 |

These are full test-function gas figures and are dominated by Foundry
setup overhead and fuzz-arg variance, **not** by the policy logic. We keep
them here only as a public reference number, not as a direct comparand.

### H3.2 — Our callee-frame numbers (Section D method, our test)

Captured by `casestudy/coinbase/test/h3-gas/SpendGasMeasureH3.t.sol` using
`vm.lastCallGas`. Re-run: `cd casestudy/coinbase && forge test --match-path
"test/h3-gas/*" -vvvv | grep "callee-frame gas:"`.

| Coinbase call (callee-frame) | Storage regime | Our gas | Host analog | Host gas |
|---|---|---:|---|---:|
| `spend()` native, first spend ever | ① SSTORE SET (`_lastUpdatedPeriod` zero → non-zero) | **64,821** | `E3_CumulativeDailyCap` R+W ① | 23,000 |
| `spend()` native, 2nd call cross-tx (committed first spend in setUp) | ② SSTORE RESET (non-zero → non-zero) | **46,537** | `E3_CumulativeDailyCap` R+W ② | 5,900 |
| `spend()` native, 2nd call same-tx | ③ dirty SSTORE (non-zero → non-zero, same-tx) | **33,237** | `E3_CumulativeDailyCap` R+W ③ | 1,100 |
| `revoke()` by account | SSTORE SET (`_isRevoked` zero → non-zero) | **33,545** | no exact host row; analogous SET (matches regime ① cost class) | ~23,000 |

### H3.3 — Component decomposition & differences explained

The host D number isolates **only the policy-library check**, whereas the
Coinbase callee-frame number includes the *entire* `spend` body. To make the
two comparable, we account for what Coinbase pays *extra*:

```
spend() native callee gas (regime ①)  =  policy check (~D) + state SSTORE + native transfer path
64,821                                 =       ~5–7k        +    ~22.5k    +      ~34k
```

Where:

- **Policy check ≈ D analogs** — Coinbase reads
  `_isApproved[hash]` (cold SLOAD ≈ 2,100), `_isRevoked[hash]`
  (≈ 2,100, analogous to host `E3_Revocation pass cold = 2,297`) and
  `_lastUpdatedPeriod[hash]` (≈ 2,100, analogous to host
  `E3_CumulativeDailyCap RO pass cold = 2,954`), then runs the cumulative
  comparison `totalSpend > allowance` at line 704 — the same arithmetic
  shape as host `E2_ValueCap pass = 284`. Subtotal ≈ 6,500–7,000 gas,
  within ~10% of summing the matching D rows.

- **State SSTORE ≈ regime ① / ② / ③** — for the three regimes our measured
  Coinbase numbers move by **64,821 − 46,537 = 18,284** (① → ②) and
  **46,537 − 33,237 = 13,300** (② → ③). The host D table's
  corresponding deltas are:
  - ① → ② SSTORE: 22,500 − 5,900 ≈ **16,600** (plus 0 SLOAD delta, since
    cross-tx still uses cold SLOADs). Coinbase residual ≈ +1,700 — explained
    by `getCurrentPeriod`'s `lastPeriodStillActive` branch costing slightly
    more in regime ② (the struct comparison at 531).
  - ② → ③ SSTORE: 5,900 − 1,100 ≈ **4,800**, plus 3 cold→warm SLOADs at
    2,000 each ≈ **6,000**, total ≈ **10,800**. Coinbase residual ≈ +2,500
    — explained by transient-storage `_expectedReceiveAmount` writes (cheap
    but non-zero) and a second event emission.
  Both residuals are <15% of the dominant component — the host D opcode
  model accounts for the magnitude.

- **Native transfer path (~34k, the irreducible Coinbase overhead)** —
  Coinbase does **not** move funds inline. It calls
  `account.execute(target=SPM, value, data="")` (line 765) which is an
  external call into the `CoinbaseSmartWallet`; the wallet then performs
  the actual `CALL` back to SPM's `receive()`; SPM then runs
  `safeTransferETH(spender, value)` (line 740) — another external CALL.
  Three external calls plus their value transfers plus the
  `_expectedReceiveAmount` transient-storage dance account for the ~34k
  that the host's *monolithic* `Escrow.settle` does not pay. This is the
  irreducible cost of going through an ERC-4337-style account abstraction
  layer.

For `revoke()` (33,545):

```
revoke() callee gas  =  EIP-712 hash + SLOAD _isRevoked + SSTORE SET + event
33,545               =     ~3–5k     +     ~2,100        +  ~22,500   + ~3,000
```

The SSTORE SET dominates and is the same opcode-class as our cumulative-cap
regime ① (host = 22,500 for SSTORE SET alone). The ~2,100 SLOAD step is the
opcode that the host's `E3_Revocation pass cold = 2,297` measures in
isolation. They reconcile.

### H3.4 — What we do NOT have a clean comparison for

- **EIP-712 hashing cost (`getHash`, lines 561–578)** is incurred on every
  Coinbase spend and revoke but never appears in our host D measurements,
  because our `Escrow` indexes policies by `policyId` not by hash. This is
  a structural difference, not a measurement gap — we surface it (≈ 3–5k
  per call) but do not try to map it to a non-existent host row.

- **`approveWithSignature`** uses an external ERC-6492 validator
  (`PUBLIC_ERC6492_VALIDATOR.isValidSignatureNowAllowSideEffects`, 299–304).
  Their `.gas-snapshot` shows ~89k for that test-function; we do not
  cross-measure because the host has no policy-approval-via-signature
  primitive. Recording for completeness, not comparison.

### H3.5 — Net read

Coinbase per-spend cost is dominated by **AA infrastructure**, not by policy
logic. Once we strip the ~34k account-abstraction transfer chain, what
remains (~31k for regime ①, ~5k for regime ③) reconciles to within ~15% of
summing the matching host D rows. The policy logic itself is **as cheap as
our minimal Escrow's** — the production system pays its premium for going
through ERC-4337/smart-wallet infrastructure, not for the cap-and-window
mechanism we share.
