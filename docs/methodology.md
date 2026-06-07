# Methodology notes

This file records the *why* behind the two non-enforceability demonstrations
(Sections F and G). The measurements and code are in `test/rconf/`,
`test/delegation/`, and the figures in `docs/figures/`.

## r_conf — why the calldata-identical test demonstrates non-enforceability (Section F)

The escrow decides whether to settle purely on its on-chain-observable input:
the call to `settle(agent, to, amount)`. In the experiment, an honest provider
and a malicious provider hold wildly different off-chain truth — the honest one
reports `reportedUsage = 100`, the malicious one reports `type(uint256).max / 2`
(about 5.79 × 10⁷⁶). Yet when each path bills the *same* amount, the calldata the
agent submits is **byte-identical**: the test asserts both `assertEq(honestCalldata,
maliciousCalldata)` and equality of their `keccak256`. The contract's entire input
is the same down to the last byte.

If the contract cannot see any difference in its input, no on-chain rule it could
contain can act on the difference. The negation test makes this structural rather
than incidental: the `settle` surface is exactly a 4-byte selector plus three
32-byte words (`agent`, `to`, `amount`) = 100 bytes, with no field that could carry
usage, an attestation, or a receipt. There is nowhere for the off-chain truth to
enter. Therefore the escrow enforces the *amount* — the R(P) ceiling — but it
cannot enforce *semantic honesty*, i.e. whether the amount faithfully reflects the
work behind it. That is the r_conf gap.

Closing the gap requires importing the off-chain truth through some trusted
channel — an oracle, a signed attestation, a TEE, or a ZK proof. Each of those
relocates the trust (to the oracle, the signer, the chip, the prover) rather than
removing it, and each carries its own cost. A bare payment primitive on an EVM
chain cannot do it, because the information needed is not in its input.

## What compositional enforcement would need to prevent the cross-hop escape (Section G)

Under local-only enforcement, every permission tracks its own `spent` against its
own `cumulativeCap`, in its own storage slot. Nothing reconciles a child's spending
against the budget its parent originally received. The escape follows directly:
User authorizes A's subtree for 2 ether; A spends 1.5 (≤ 2, locally fine) and
re-grants B a *fresh* 2-ether budget; B spends 2.0 (≤ 2, locally fine); the single
pool pays out 3.5 ether — exceeding the 2 ether the user authorized — while **no
local cap is ever violated**. The control test confirms a single hop cannot exceed
its own cap, so the escape is genuinely compositional: it lives in the gap between
local caps and the absent global accounting.

To prevent it, enforcement would have to make every spend answer a *global*
question, not just a local one. Concretely it would need to track, per settlement,
the cumulative spend of the entire delegation subtree rooted at the original grant,
and check each spend against every ancestor's remaining budget. Two shapes do this:
(a) a single shared budget object that the root grant creates and every descendant
debits atomically — so A and B draw down the *same* 2-ether counter; or (b)
ancestor traversal on every `execute`, walking the `parent` chain and decrementing
each ancestor's remaining allowance, reverting if any ancestor is exhausted.

Both add state and gas that scale with delegation depth. We measured the single-hop
cumulative-cap check in isolation — about 2,954 gas for the read and ~5,900 for the
read-plus-write (repeat-day SSTORE_RESET path) — so option (b) multiplies roughly
that per-hop cost by the depth of the chain on every settlement, and option (a)
trades the traversal for contention on one hot slot. We do **not** implement
compositional enforcement; the purpose here is to bound what it would cost and to
make explicit that the escape is a missing-mechanism problem, not a bug in the
local checks, which behave exactly as written.

## Why a fixed window admits a reset burst, and what a value-sliding window would need (adversarial test T4)

`E3_CumulativeDailyCap` keys its window on `block.timestamp / 1 days`: the counter
resets the instant that integer quotient changes. Adversarial test T4
(`test/adversarial/AttackVectors.t.sol`) exploits exactly this — settling the full
daily cap at `2 days − 1` (day index 1) and again at `2 days + 1` (day index 2)
drains 2× the cap within ~2 seconds of wall-clock time, with no policy violated.
This is Zhang et al.'s (2026, §5.2) "timing manipulation" attack, demonstrated on
our own escrow; it is recorded as limitation 9 in the final report.

The natural mitigation mirrors `E3_SlidingWindowRateLimit`'s two-bucket
approximation, but applied to *value* rather than *count*: instead of one `(dayStart,
spent)` pair, the policy would weight the previous window's spend by the fraction of
the window not yet elapsed (`weighted = currSpent + prevSpent · (W − elapsed) / W`)
and check that against the cap. That smooths the boundary so a pre-reset + post-reset
pair can no longer both pass at full value. We implemented the count-based form
(`E3_SlidingWindowRateLimit`) and measured it; the value-based form was not
implemented, so the burst stands as a demonstrated limitation rather than a closed
gap. The cost class would match the count-based module — one packed-slot read + one
write per check (§5.1) — since the state shape (windowStart + two weighted buckets)
is identical; only the accumulated quantity changes from a count to a wei value.
