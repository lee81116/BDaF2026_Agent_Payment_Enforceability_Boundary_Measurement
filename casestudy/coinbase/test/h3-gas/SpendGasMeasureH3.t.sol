// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {SpendPermissionManager} from "../../src/SpendPermissionManager.sol";
import {SpendPermissionManagerBase} from "../base/SpendPermissionManagerBase.sol";

/// @title SpendGasMeasureH3Base — shared setup for H3 callee-frame gas tests
///
/// @notice Section H3 measurement infrastructure. Numbers come from
///         `vm.lastCallGas().gasTotalUsed` captured on the external call to
///         `SpendPermissionManager`, mirroring the host-repo Section D method.
///         They are NOT directly comparable to `casestudy/coinbase/.gas-snapshot`,
///         which is `forge --gas-report`-style and bundles caller-side overhead.
///
/// @dev    Compile profile: `casestudy/coinbase/foundry.toml` (Coinbase's
///         settings, with solc pinned at 0.8.35 — the version under which the
///         recorded H3 numbers were captured). Host repo's `foundry.toml`
///         (solc 0.8.26 / optimizer 200 / via_ir=false) is untouched
///         (golden rule #1).
///
/// @dev    Logging: emits DSTest `log_named_uint` events, which forge decodes
///         natively under `-vv`. Two-arg `console2.log(string, uint256)` was
///         silently reverting inside the console precompile under the
///         forge-std version Coinbase pins (commit `58d3051`) + forge 1.7.1
///         (unknown selector `0x9710a9d0` for `ConsoleCalls`), so the gas
///         numbers were only visible under `-vvvv` traces. The DSTest path
///         is version-independent.
abstract contract SpendGasMeasureH3Base is SpendPermissionManagerBase {
    SpendPermissionManager.SpendPermission internal perm;

    /// Spend value well under `allowance` (1 ether) so every measured call
    /// takes the "pass" path through `_useSpendPermission`.
    uint160 internal constant SPEND_VALUE = 0.001 ether;

    function _baseSetUp() internal {
        _initializeSpendPermissionManager();

        // Authorise SPM to call `execute` on the smart account. Lives in setUp
        // so the SSTORE commits in tx0 (separate from each test_* tx).
        vm.prank(owner);
        account.addOwnerAddress(address(mockSpendPermissionManager));

        // Approve a native-token permission. Caller must be the account per
        // `requireSender(spendPermission.account)`.
        perm = _createSpendPermission();
        vm.prank(address(account));
        mockSpendPermissionManager.approve(perm);

        // Fund the account so `_transferFrom` can move native value.
        vm.deal(address(account), 1 ether);
        // Pre-touch the spender account so the credit isn't a 25k
        // account-creation surcharge (same pattern as our batch curve).
        vm.deal(spender, 1 wei);
    }

    /// Measure callee-frame gas of one `spend()` and assert it matches the
    /// recorded value to within ±2 gas. Golden rule #2: if the measured
    /// number drifts, open a trace and fix the opcode model — never widen
    /// the tolerance.
    function _measureSpend(string memory label, uint256 expected) internal {
        bytes memory cd = abi.encodeCall(SpendPermissionManager.spend, (perm, SPEND_VALUE));
        vm.prank(spender);
        (bool ok,) = address(mockSpendPermissionManager).call(cd);
        require(ok, "spend reverted");

        uint256 gasUsed = vm.lastCallGas().gasTotalUsed;
        emit log_named_uint(label, gasUsed);
        assertApproxEqAbs(gasUsed, expected, 2);
    }
}

/// @title SpendGasMeasureH3 — first-spend SET, dirty same-tx, revoke
contract SpendGasMeasureH3 is SpendGasMeasureH3Base {
    function setUp() public {
        _baseSetUp();
    }

    /// Regime ①: first spend ever — `_lastUpdatedPeriod[hash]` SSTORE goes
    /// zero → non-zero. Host analog: `E3_CumulativeDailyCap` R+W ①
    /// (~23,000 for the SSTORE alone). Total spend() callee gas is dominated
    /// by this SSTORE plus the native-transfer external-call chain.
    function test_gas_spend_native_cold_SET() public {
        vm.warp(perm.start);
        _measureSpend("[H3] spend native cold (SET regime) callee-frame gas", 64_821);
    }

    /// Regime ③: second spend in the SAME tx — the `_lastUpdatedPeriod[hash]`
    /// slot is "dirty" (modified earlier in this tx). Host analog:
    /// `E3_CumulativeDailyCap` R+W ③ (~1,100 for the SSTORE).
    /// NOTE: regime ③ is NOT a realistic per-tx cost (we never charge two
    /// spends in one tx in production). We measure it only to expose the
    /// EVM cold/warm/dirty distinction, matching the host doc's caveat.
    function test_gas_spend_native_dirty_sameTx() public {
        vm.warp(perm.start);
        bytes memory cd = abi.encodeCall(SpendPermissionManager.spend, (perm, SPEND_VALUE));
        vm.prank(spender);
        (bool ok1,) = address(mockSpendPermissionManager).call(cd);
        require(ok1, "first spend reverted");

        _measureSpend("[H3] spend native warm dirty (regime 3) callee-frame gas", 33_237);
    }

    /// Account-side revoke. Dominant write is `_isRevoked[hash]` going
    /// zero → non-zero (SSTORE SET, ~22,500). This is the full revoke tx,
    /// not the per-spend revocation *check*. The host's `E3_Revocation`
    /// (~2,297 cold) measures the per-spend SLOAD, which inside Coinbase
    /// corresponds to `isValid()` reading `_isRevoked` during
    /// `_useSpendPermission` — already inside the cold-spend total above.
    function test_gas_revoke_byAccount_SET() public {
        bytes memory cd = abi.encodeCall(SpendPermissionManager.revoke, (perm));
        vm.prank(address(account));
        (bool ok,) = address(mockSpendPermissionManager).call(cd);
        require(ok, "revoke reverted");

        uint256 gasUsed = vm.lastCallGas().gasTotalUsed;
        emit log_named_uint("[H3] revoke by account (SSTORE SET) callee-frame gas", gasUsed);
        assertApproxEqAbs(gasUsed, 33_545, 2);
    }
}

/// @title SpendGasMeasureH3_Reset — Regime ② (cross-tx RESET)
///
/// @dev setUp commits the first spend in tx0; the measured call in tx1
///      hits the EIP-3529 RESET path for `_lastUpdatedPeriod[hash]`
///      (~5,900 for the SSTORE) plus a cold SLOAD on the slot
///      (EIP-2929 access list resets between txs). Host analog:
///      `E3_CumulativeDailyCap` R+W ② (~5,900).
contract SpendGasMeasureH3_Reset is SpendGasMeasureH3Base {
    function setUp() public {
        _baseSetUp();
        // Commit the first spend in tx0 — its SSTORE persists for tx1.
        vm.warp(perm.start);
        vm.prank(spender);
        mockSpendPermissionManager.spend(perm, SPEND_VALUE);
    }

    function test_gas_spend_native_crossTx_RESET() public {
        _measureSpend("[H3] spend native cross-tx (RESET regime) callee-frame gas", 46_537);
    }
}
