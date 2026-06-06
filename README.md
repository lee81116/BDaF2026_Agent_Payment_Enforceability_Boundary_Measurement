# Agent Payment Enforceability — Boundary Measurement

Foundry project measuring **which on-chain payment policies for autonomous agents are
actually enforceable, and at what gas cost** — across two axes: policy expressiveness
(E1 access / E2 transaction / E3 contextual & stateful, after Zhang et al. 2026) and
enforcement properties (r_rev / r_scope / r_conf, instantiating Shi et al.'s 2025
B-I-P risk decomposition at the settlement boundary).

**Thesis (settlement-boundary model):** on-chain mechanisms enforce the
*chain-observable ceiling* of a payment policy — amounts, windows, single-hop scope,
revocation — cheaply and attributably. Semantic honesty (r_conf) and, absent
root-anchored global state, cross-hop scope (r_scope) break structurally. The smart
account replaces the absent human, not the credit card.

📄 **Full report: [`docs/final-report.md`](docs/final-report.md)** — definitions,
methodology, complete measurement tables, threat model, limitations, and the
prediction-vs-verdict ledger. Evidence dossiers:
[`docs/gas-results.md`](docs/gas-results.md) (per-check opcode accounts),
[`docs/case-study-coinbase.md`](docs/case-study-coinbase.md),
[`docs/case-study-metamask.md`](docs/case-study-metamask.md),
[`docs/case-study.md`](docs/case-study.md) (synthesis).

## Headline results

| Result | Number | Where |
|---|---|---|
| Stateless checks (3× E2 caps, depth bound) | **284 / 308** gas, all identical; depth revert 350 (+42 = 2-arg error) | §5.1a |
| Single-SLOAD checks (E1 allowlists, expiry, revocation) | 2,296–2,557 cold / 296–557 warm; cold−warm = 2,000 everywhere; Target−Selector = 26 on all four paths | §5.1b |
| One SSTORE, three regimes | daily cap **23,000 / 5,900 / 1,100** (SET / RESET / dirty); sliding window (two-bucket) **23,834 / 6,734 / 1,934** — arithmetic provably constant (1,734) | §5.1c |
| Batch curve, exact linear fit | marginals **identical** for E2-only and full-E3 baselines (10,026) → batch-level E3 core costs **+2.4%** at N = 50 | §5.2 |
| r_conf break (Section F) | honest vs malicious settlement **byte-identical** (100-byte surface; no field can carry truth) | §6.1 |
| Cross-hop r_scope break (Section G) | **3.5 ETH drained from a 2 ETH authorization**, no local cap violated; depth bounds don't fix it (escape replays at legal depth) | §6.2 |
| Production closure price | MetaMask closes the cross-hop gap at **63,396 gas** (2-layer redemption, caller-side) | §7.2 |
| Production strategies | Coinbase *restricts the surface* · MetaMask *pays to walk the chain* · x402 *leaves the chain* — none attempts r_conf on-chain | §7 |
| Verification | host **102/102**, Coinbase case study **4/4**, MetaMask **2/2**; every gas number asserted at **±2** and reproduced bit-exact cross-OS | §10 |

Every claim traces to a passing test or a documented structural argument; gas
numbers are *predicted from an opcode model first*, then asserted (`±2`) — misses
fix the model, never the tolerance.

## Toolchain (pinned — do not change without re-baselining gas)

- **forge / cast / anvil**: 1.7.1 (commit `4072e48705`, build 2026-05-08)
- **solc**: 0.8.26 (set in `foundry.toml`, auto-downloaded by forge)
- **forge-std**: v1.16.1 (vendored under `lib/forge-std`, no submodule init needed)
- Case studies build under **their own** pinned profiles (`casestudy/*/foundry.toml`,
  Coinbase solc pinned 0.8.35) — never merged into the host profile.

## Layout

```
src/
  Escrow.sol                 # Section B — minimal per-agent ETH escrow
  policies/                  # Sections C + E3 extensions — 10 policy modules
  baselines/                 # Section E — no-policy & E2-only batch baselines
  mocks/                     # Section F — Mock/Malicious providers
  delegation/                # Section G — TwoHopDelegation + DepthBoundedDelegation
test/
  BaseTest.sol  policies/  batch/  rconf/  delegation/
casestudy/
  coinbase/                  # Spend Permissions v1.0.0 @ 54e99c7e (see VERSION.md)
  metamask/                  # Delegation Framework v1.3.0 @ bfbdf979 (see VERSION.md)
snapshots/                   # baseline.snap (frozen) · current.snap (live)
docs/                        # final-report.md · gas-results.md · batch-curve.csv
                             # case-study*.md · figures/
foundry.toml  Makefile  README.md  CLAUDE.md
```

## Reproduce every number

```bash
forge --version     # must be 1.7.1 (4072e487)
make build && make test          # host: 102 passed / 0 failed (gas assertions included)
make snap-check                  # 0 drift vs snapshots/current.snap

# Section E batch curve, regenerated row-by-row:
forge test --match-path test/batch/BatchCurve.t.sol -vv | grep '^CSV,'

# Case studies (vendored pins in casestudy/*/VERSION.md; lib/ re-fetch steps inside):
cd casestudy/coinbase  && forge test --match-path "test/h3-gas/*" -vv      # 4 PASS, ±2 asserted
cd casestudy/metamask  && forge test --match-path "test/h5-crosshop/*" -vv # 2 PASS, 63,396 asserted
```

## Commands

- `make build` — compile · `make test` — run tests (`forge test -vvv`)
- `make snap` — write `snapshots/current.snap` · `make snap-check` — diff against it
- `make gas-report` — `forge --gas-report` dump (NOT used for per-check results; see
  `docs/gas-results.md` for why — it once reported a phantom 44,505 for a true 23,041)

## foundry.toml — line-by-line

- `solc_version = "0.8.26"` — pins the compiler; the single biggest reproducibility lever for gas.
- `optimizer = true`, `optimizer_runs = 200` — changing either invalidates all recorded gas numbers.
- `via_ir = false` — legacy codegen, so opcode-level reasoning matches what you read.
- `gas_reports = ["*"]` — emit gas reports for every contract.
- `[profile.default.fuzz] runs = 256` — fuzz iterations per property test.
- `[fmt]` — `forge fmt` style: 100-col lines, 4-space tabs, no inner bracket spacing.

## Getting started

```bash
git clone <repo-url>
cd agent-payment-enforceability
make build && make test
```

Install Foundry first if needed: https://getfoundry.sh — then `foundryup -i 1.7.1`
to match the pin. Host `lib/forge-std` is vendored; `casestudy/*/lib` is gitignored —
re-fetch instructions live in each `casestudy/*/VERSION.md`.

## References

- Zhang, Y., et al. (2026). *SoK: Blockchain agent-to-agent payments* (arXiv:2604.03733). — E1/E2/E3 expressiveness taxonomy (§4.2).
- Shi, G., et al. (2025). *SoK: Trust-authorization mismatch in LLM agent interactions* (arXiv:2512.06914). — B-I-P framework; `R_P = max(r_conf, r_rev, r_scope)` (eq. 5, §3.5).
