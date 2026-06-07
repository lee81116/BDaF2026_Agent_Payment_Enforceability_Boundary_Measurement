// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "../BaseTest.sol";
import {Escrow} from "../../src/Escrow.sol";
import {E3_CumulativeDailyCap} from "../../src/policies/E3_CumulativeDailyCap.sol";
import {ReentrantRecipient} from "../../src/mocks/ReentrantRecipient.sol";

/// @notice Adversarial demonstrations — each test turns a prose threat-model row
///         into an executable claim. Every test names its literature source
///         (Zhang et al. 2026 §5.2 category, or SWC-107). Background and the full
///         coverage map: `docs/threat-coverage.md`.
///
/// These are BEHAVIORAL tests (revert / balance / counter assertions), not gas
/// tests — no gas predictions here. The escrow under attack is `src/Escrow.sol`,
/// deployed fresh per test with the test contract as `user` (it deploys it).
contract AttackVectorsTest is BaseTest {
    Escrow internal escrow;

    function setUp() public override {
        super.setUp();
        escrow = new Escrow(); // deployer == `user`; this test contract owns setPolicy
        vm.deal(address(this), 1000 ether);
    }

    function _setPolicy(uint256 maxPerRequest, uint256 maxPerDay) internal {
        escrow.setPolicy(
            AGENT,
            Escrow.AgentPolicy({
                maxPerRequest: maxPerRequest,
                maxPerDay: maxPerDay,
                validUntil: type(uint256).max, // never expires within these tests
                active: true
            })
        );
    }

    // T1 — Reentrancy is bounded by the cumulative cap (SWC-107). -------------

    /// `Escrow.settle` follows checks-effects-interactions: it commits
    /// `dailyState[agent]` and `balances[agent]` BEFORE the external `to.call`.
    /// So when the recipient re-enters `settle`, `advance()` already sees
    /// `spent == maxPerDay` and reverts `ExceedsDailyCap`; the reentrant pull
    /// cannot draw a second ether. Reentrancy is bounded by the cap, with no
    /// explicit reentrancy guard. Source: SWC-107.
    /// Verified: recipient balance == exactly 1 ether; one reentry attempt, blocked.
    function test_T1_ReentrancyBoundedByCumulativeCap() public {
        _setPolicy(1 ether, 1 ether);
        escrow.deposit{value: 10 ether}(AGENT);

        ReentrantRecipient attacker = new ReentrantRecipient(escrow, AGENT);
        escrow.settle(AGENT, payable(address(attacker)), 1 ether);

        assertLe(address(attacker).balance, 1 ether, "reentrancy must not exceed the daily cap");
        assertEq(address(attacker).balance, 1 ether, "exactly one ether: the reentry was blocked");
        assertEq(attacker.hits(), 1, "exactly one reentry attempt occurred");

        (, uint128 spent) = escrow.dailyState(AGENT);
        assertEq(spent, 1 ether, "spent committed at the cap before the call (CEI)");
        assertEq(escrow.getBalance(AGENT), 9 ether, "only one ether left the pool");
    }

    // T2 — Replay/repetition is bounded, not prevented (Zhang §5.2). ----------

    /// Zhang et al. 2026 §5.2 "repetition". There is no per-settlement nonce, so
    /// five identical `settle` calls are NOT rejected as duplicates. The daily cap
    /// is the only bound: with cap 3 ether, the first three (1 ether each) succeed
    /// and the 4th and 5th revert `ExceedsDailyCap`. Replay is bounded, not
    /// prevented — the executable form of threat-model rows K4/K5.
    /// Verified: to.balance == 3 ether; calls 4 and 5 revert.
    function test_T2_ReplayBoundedNotPrevented() public {
        _setPolicy(1 ether, 3 ether);
        escrow.deposit{value: 10 ether}(AGENT);

        // The SAME call, replayed. No nonce means no duplicate-rejection.
        for (uint256 i = 0; i < 3; i++) {
            escrow.settle(AGENT, payable(PROVIDER), 1 ether);
        }
        for (uint256 i = 0; i < 2; i++) {
            vm.expectRevert(E3_CumulativeDailyCap.ExceedsDailyCap.selector);
            escrow.settle(AGENT, payable(PROVIDER), 1 ether); // 4th, 5th: over the daily cap
        }

        assertEq(PROVIDER.balance, 3 ether, "bounded by the daily cap, not by duplicate-rejection");
    }

    // T3 — Fragmentation: per-request cap alone does not bound total (Zhang §5.2).

    /// Zhang et al. 2026 §5.2 "fragmentation". Every spend (0.5 ether) is under
    /// the per-request cap (1 ether), so a per-request (E2) cap alone would let
    /// fragmentation run unbounded. Only the cumulative (E3) cap bounds the total:
    /// six 0.5-ether spends reach exactly the 3-ether daily cap, and the seventh
    /// reverts. This is the affirmative case for why the E3 cap is load-bearing.
    /// Verified: spends 1-6 sum to 3 ether; the 7th reverts.
    function test_T3_FragmentationBoundedOnlyByCumulativeCap() public {
        _setPolicy(1 ether, 3 ether);
        escrow.deposit{value: 10 ether}(AGENT);

        for (uint256 i = 0; i < 6; i++) {
            escrow.settle(AGENT, payable(PROVIDER), 0.5 ether); // each strictly under the per-request cap
        }
        assertEq(PROVIDER.balance, 3 ether, "six sub-cap fragments sum to exactly the daily cap");

        vm.expectRevert(E3_CumulativeDailyCap.ExceedsDailyCap.selector);
        escrow.settle(AGENT, payable(PROVIDER), 0.5 ether); // 7th fragment: cumulative cap stops it
    }

    // T4 — Timing manipulation: fixed-window value cap allows a 2x burst (Zhang §5.2).

    /// Zhang et al. 2026 §5.2 "timing manipulation" — a NEGATIVE result, stated
    /// honestly. `CumulativeDailyCap` is a FIXED window keyed on
    /// `block.timestamp / 1 days`. Spending the full cap just before a day
    /// boundary and again just after drains 2x the daily cap within ~2 seconds of
    /// wall-clock time. `E3_SlidingWindowRateLimit` would mitigate this for the
    /// request-RATE (count) dimension, but it is count-based, not value-based; a
    /// sliding-window VALUE cap was not implemented, so this value burst is a real
    /// limitation of the fixed-window `CumulativeDailyCap` (see final-report
    /// limitations and docs/methodology.md).
    /// Verified: to.balance == 2 ether across the boundary.
    function test_T4_FixedWindowAllowsBurstAcrossReset() public {
        _setPolicy(1 ether, 1 ether);
        escrow.deposit{value: 10 ether}(AGENT);

        vm.warp(2 days - 1); // day index 1: (172799 / 86400) == 1
        escrow.settle(AGENT, payable(PROVIDER), 1 ether); // fills day 1 to the cap

        vm.warp(2 days + 1); // day index 2: (172801 / 86400) == 2 — counter resets
        escrow.settle(AGENT, payable(PROVIDER), 1 ether); // a second full cap, ~2s later

        assertEq(PROVIDER.balance, 2 ether, "2x the daily cap across the fixed-window reset");
    }
}
