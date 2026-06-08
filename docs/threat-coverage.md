# Threat / attack coverage — what we test, the literature it maps to, and the gaps

Working doc. Scope reminder (report §1): this project measures the **payment-authorization
boundary at the on-chain policy layer** — blast radius, not decision quality. "Attack"
here means an adversary trying to move value in a way the policy layer should stop.
We separate two things the suite does, because they are not the same:

- **Adversarial demonstration** — an attacker actively tries to break a property; the
  test's assertion *is* the research claim (attack succeeds = a structural limit;
  attack blocked = a defense holds).
- **Guardrail conformance** — a cap simply works (over-cap reverts). Maps to a threat
  row, but it is not an exploit.

## Literature basis (the two SoKs we build on)

The attack vocabulary is **not invented here** — it is Zhang et al.'s risk taxonomy,
read directly from the PDF:

- **Zhang et al. 2026, §5.2 "Delegated Authorization and Spend Control Risks"**
  (arXiv:2604.03733). Verbatim categories:
  - *Technical level*: a compromised agent (prompt injection, model manipulation, key
    leakage, software vuln, social engineering) "may generate transactions that satisfy
    authorization policies … resulting transactions remain admissible."
  - *Transaction level*: "sequences of valid transactions may violate intended spending
    boundaries through **repetition, fragmentation, or timing manipulation**."
  - *Multi-entity*: "**colluding agents** distribute actions across identities while
    remaining locally compliant."
  - *Legal level*: standing delegation is granted ex ante with "no re-evaluation of
    purpose or cumulative impact" (consent drift).
- **Zhang et al. §5.1** (discovery): counterparty spoofing, intent replay/mismatch.
- **Zhang et al. §5.3** (execution/settlement): "payment completion is weakly coupled to
  service completion" — provider paid without correct delivery; trust extended to
  bundlers/relayers/paymasters.
- **Zhang et al. §5.4** (accounting): causal attribution gap (a transfer is recorded,
  not *why* it happened or *who* is responsible).
- **Shi et al. 2025** (arXiv:2512.06914): the B-I-P framework — the *upstream cause* of
  the §5.2 "compromised agent" clause is belief/intent corruption (prompt injection,
  tool poisoning). This is the part our framework explicitly does **not** enforce
  (it is T(B,I), not P).
- **Reentrancy** is the one attack not covered by either SoK (they are payment-semantics
  papers, not EVM-exploit papers). Canonical source: SWC-107 / Consensys smart-contract
  best practices. We test it because it threatens the *integrity of every cap claim*.

## Coverage map (current suite)

| # | Attack | Literature | Test | Type | Result |
|---|---|---|---|---|---|
| 1 | Dishonest billing / over-reporting usage | Zhang §5.2 (misuse under valid auth) + §5.3 (payment ≠ delivery); Shi B-I-P intent corruption | `test/rconf/CalldataIdentical.t.sol` | adversarial | **Attack succeeds (structural)** — honest vs malicious settlement byte-identical; escrow cannot distinguish |
| 2 | Cross-hop budget escape via re-delegation | Zhang §5.2 (valid-sequence boundary violation; multi-entity composition); capability-security attenuation | `test/delegation/CrossHopEscape.t.sol` | adversarial | **Attack succeeds** under local-only state — 3.5 ETH drained from 2 ETH authorization, no local cap violated. **Now closed host-side: see #14** (the escape demo stays, unchanged) |
| 3 | Same escape within a legal depth bound | same as #2 | `test/delegation/DepthBoundEscape.t.sol` | adversarial | **Attack succeeds** — depth bound limits chain length, not budget (closed by root-anchored state, not depth: #14) |
| 4 | Cross-hop overspend against a production framework | same as #2 | `casestudy/metamask/test/h5-crosshop/CrossHopEnforcement.t.sol` | adversarial | **Attack blocked** — root-anchored hash-keyed counter; closure costs 63,396 gas (caller-side). Host-side analog now measured at 9,625 gas/hop callee-frame: #14 |
| 14 | Cross-hop budget escape — **host-side closure** | Zhang §5.2; methodology.md option (b) | `test/delegation/RootAnchoredClosure.t.sol` (+ `_Gas`) | adversarial | **Attack blocked** — `RootAnchoredDelegation` walks the parent chain and debits every ancestor's root-anchored counter; A's 1.5 + B's 2.0 reverts at the 2-ETH root cap. Closure measured at **9,625 gas/hop** callee-frame (constant; O(depth) law) — comparable to the E3 RESET row, unlike #4's caller-side figure |
| 5 | Malformed policy parameter (W=0; weight overflow) | fail-closed principle (defensive design) | `test/policies/E3_SlidingWindowRateLimit.t.sol` (fail-closed tests, in `d29db52`) | fault-injection | **Fails closed** — division/overflow panic, never allow-all |
| 6 | Agent exceeds per-request cap | Zhang §5.2 (transaction-level bound) | `E2_*` revert tests; `EscrowBasic` | conformance | blocked |
| 7 | Agent exceeds cumulative daily budget | Zhang §5.2 | `E3_CumulativeDailyCap*`; `EscrowBasic` | conformance | blocked |
| 8 | Spend under expired / revoked authority | Zhang §5.2 (reactive revocation; consent drift) | `E3_Expiry`, `E3_Revocation` | conformance | blocked |
| 9 | Call to disallowed target / selector | Zhang §4.2 E1 (access-level) | `E1_*` | conformance | blocked (module-level) |
| 10 | Reentrancy on `settle` | SWC-107 | `test/adversarial/AttackVectors.t.sol::T1` | adversarial | **Bounded by the cap** — CEI commits `dailyState`/`balances` before the external call; reentrant `settle` reverts `ExceedsDailyCap`, recipient capped at exactly 1 ETH (no reentrancy guard needed) |
| 11 | Repetition / replay of a settlement | Zhang §5.2 "repetition" | `test/adversarial/AttackVectors.t.sol::T2` | adversarial | **Bounded, not prevented** — no per-settlement nonce; 5 identical calls, first 3 succeed, 4th/5th revert; total == daily cap (a ceiling, not uniqueness) |
| 12 | Fragmentation (split into sub-cap spends) | Zhang §5.2 "fragmentation" | `test/adversarial/AttackVectors.t.sol::T3` | adversarial | **Bounded only by the E3 cap** — 6 × 0.5 ETH (each under per-request cap) sum to the 3-ETH daily cap, 7th reverts; a per-request cap alone would not bound it |
| 13 | Timing manipulation (burst across reset) | Zhang §5.2 "timing manipulation" | `test/adversarial/AttackVectors.t.sol::T4` | adversarial | **Attack succeeds (negative result)** — fixed-window `CumulativeDailyCap` admits 2× the cap within ~2s across a day boundary; count-based sliding window does not close the *value* burst |

## Gap analysis — named attacks with no dedicated test

| Gap | Literature | In scope? | Verified expectation (sandbox) | Status |
|---|---|---|---|---|
| **A. Reentrancy** on `settle`/`batchDeduct` | SWC-107 | **Yes** — tests integrity of every cap | Recipient capped at exactly the daily cap; CEI commits state before the external call, reentrant `settle` reverts | **✅ tested — #10 (T1)** |
| **B. Repetition / replay** of a settlement | Zhang §5.2 "repetition" | **Yes** — concretizes threat-model "replay bounded, not prevented" | No per-settlement nonce; N replays bounded by daily cap, not blocked | **✅ tested — #11 (T2)** |
| **C. Fragmentation** (split one spend into many sub-cap spends) | Zhang §5.2 "fragmentation" | **Yes** | Per-request cap alone does not bound the total; daily cap does | **✅ tested — #12 (T3)** |
| **D. Timing manipulation** (burst across the window reset) | Zhang §5.2 "timing manipulation" | **Yes — and it's a new negative result** | **Confirmed: fixed-window `CumulativeDailyCap` admits 2× cap within ~2s across a day boundary.** The sliding-window module is *count-based*, so it does not close the *value* burst — an honest limitation, not a fix | **✅ tested — #13 (T4)**, recorded as final-report limitation 9 |
| E. Collusion (multi-identity) | Zhang §5.2 multi-entity | Partial | structurally identical to cross-hop (#2) | note, no new test |
| F. Counterparty spoofing | Zhang §5.1 | No | discovery stage; we do not model discovery | out of scope (state it) |
| G. Service-not-delivered | Zhang §5.3 | No | r_conf-adjacent; structurally argued in #1; tier-(iii) imported truth | out of scope (covered by F-argument) |
| H. Prompt injection / tool poisoning | Shi et al. | No | corrupts T(B,I); we enforce P only — caps still bound the damage | out of scope (state it) |
| I. Revocation front-running (revoke race) | Zhang §5.2 | Maybe | Coinbase's `approveWithRevoke` addresses this; our `settle` is permissionless | note as future work |

**Headline for the gap work:** items A–D are now implemented (coverage rows #10–#13,
`test/adversarial/AttackVectors.t.sol`) — each turns a prose threat-model row into an
executable adversarial test, and D produced a genuinely new finding (fixed-window value
caps are burst-vulnerable at the reset — the canonical "timing manipulation" attack,
named by Zhang §5.2, demonstrated on our own escrow and recorded as final-report
limitation 9). Items F–H remain correctly out of scope and are stated as such, not
silently omitted.

Status: A–D delivered under a red→green→docs TDD trail (PR #5, commits
`875c487` red → `9780407` green → `ea68909` docs).
