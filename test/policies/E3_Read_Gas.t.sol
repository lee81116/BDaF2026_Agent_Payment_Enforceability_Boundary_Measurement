// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {GasMeasure} from "./GasMeasure.sol";
import {E3_Expiry_Harness} from "../../src/policies/E3_Expiry.sol";
import {E3_Revocation_Harness} from "../../src/policies/E3_Revocation.sol";

/// @notice D-4 — E3 single-SLOAD stateful reads (Expiry, Revocation).
///
/// Both harnesses read a fixed (non-mapping) storage slot — no keccak step, no
/// calldata args, just `SLOAD slot0 + compare + JUMPI`. Expected to be cheaper
/// than E1 (which pays for keccak + decode of one arg).
///
/// Opcode account (callee-frame, measured under pinned toolchain):
///   Expiry pass warm      = 296   (warm SLOAD + dispatch + TIMESTAMP + GT + JUMPI)
///   Revocation pass warm  = 297   (Revocation pays +1 gas — bool-SLOAD
///                                  sanitization Solidity emits after the load)
///   cold − warm           = 2000  (per EIP-2929: cold SLOAD 2100, warm 100)
///   revert overhead       = +30   (E1 was +26; the extra 4 gas comes from the
///                                  pass/revert JUMPI fork landing on different
///                                  code blocks here)
///
/// Cold/warm split:
///   - setUp seeds harnesses (SSTOREs warm setUp's tx access list, reset on
///     each test entry — first read in test_* is cold).
///   - Warm tests pre-touch the slot in the test body via the public getter
///     (validUntil() / active()) before measuring.
///
/// Pass vs revert: use separate harnesses with different stored state so the
/// pass/revert paths share the same fresh access list per test.
contract E3_Read_GasTest is GasMeasure {
    E3_Expiry_Harness internal expPass;
    E3_Expiry_Harness internal expRevert;
    E3_Revocation_Harness internal revPass;
    E3_Revocation_Harness internal revRevert;

    // Predictions (pinned toolchain). Drift > TOL means the opcode model
    // changed; trace and explain, do not widen.
    uint256 internal constant PRED_EXP_PASS_COLD = 2296;
    uint256 internal constant PRED_EXP_PASS_WARM = 296;
    uint256 internal constant PRED_EXP_REVERT_COLD = 2326;
    uint256 internal constant PRED_EXP_REVERT_WARM = 326;
    uint256 internal constant PRED_REV_PASS_COLD = 2297;
    uint256 internal constant PRED_REV_PASS_WARM = 297;
    uint256 internal constant PRED_REV_REVERT_COLD = 2327;
    uint256 internal constant PRED_REV_REVERT_WARM = 327;
    uint256 internal constant TOL = 2;

    function setUp() public override {
        super.setUp();
        expPass = new E3_Expiry_Harness();
        expRevert = new E3_Expiry_Harness();
        revPass = new E3_Revocation_Harness();
        revRevert = new E3_Revocation_Harness();

        // Pass-side state.
        expPass.setValidUntil(type(uint256).max);
        revPass.setActive(true);
        // Revert-side: leave slots at zero (never SSTOREd). SLOAD still pays
        // cold 2100 / warm 100 — the access-list cost is independent of the
        // stored value. Default block.timestamp = 1 > validUntil(0) → Expired;
        // active(false) → PolicyInactive.
    }

    // ---------- E3_Expiry -----------------------------------------------------

    function test_gas_E3_Expiry_pass_cold() public {
        uint256 g =
            _measure(address(expPass), abi.encodeCall(E3_Expiry_Harness.checkExternal, ()), true);
        emit log_named_uint("E3_Expiry pass cold", g);
        assertApproxEqAbs(g, PRED_EXP_PASS_COLD, TOL, "E3_Expiry pass cold off prediction");
    }

    function test_gas_E3_Expiry_pass_warm() public {
        expPass.validUntil(); // warm the slot
        uint256 g =
            _measure(address(expPass), abi.encodeCall(E3_Expiry_Harness.checkExternal, ()), true);
        emit log_named_uint("E3_Expiry pass warm", g);
        assertApproxEqAbs(g, PRED_EXP_PASS_WARM, TOL, "E3_Expiry pass warm off prediction");
    }

    function test_gas_E3_Expiry_revert_cold() public {
        uint256 g = _measure(
            address(expRevert), abi.encodeCall(E3_Expiry_Harness.checkExternal, ()), false
        );
        emit log_named_uint("E3_Expiry revert cold", g);
        assertApproxEqAbs(g, PRED_EXP_REVERT_COLD, TOL, "E3_Expiry revert cold off prediction");
    }

    function test_gas_E3_Expiry_revert_warm() public {
        expRevert.validUntil();
        uint256 g = _measure(
            address(expRevert), abi.encodeCall(E3_Expiry_Harness.checkExternal, ()), false
        );
        emit log_named_uint("E3_Expiry revert warm", g);
        assertApproxEqAbs(g, PRED_EXP_REVERT_WARM, TOL, "E3_Expiry revert warm off prediction");
    }

    // ---------- E3_Revocation -------------------------------------------------

    function test_gas_E3_Revocation_pass_cold() public {
        uint256 g = _measure(
            address(revPass), abi.encodeCall(E3_Revocation_Harness.checkExternal, ()), true
        );
        emit log_named_uint("E3_Revocation pass cold", g);
        assertApproxEqAbs(g, PRED_REV_PASS_COLD, TOL, "E3_Revocation pass cold off prediction");
    }

    function test_gas_E3_Revocation_pass_warm() public {
        revPass.active();
        uint256 g = _measure(
            address(revPass), abi.encodeCall(E3_Revocation_Harness.checkExternal, ()), true
        );
        emit log_named_uint("E3_Revocation pass warm", g);
        assertApproxEqAbs(g, PRED_REV_PASS_WARM, TOL, "E3_Revocation pass warm off prediction");
    }

    function test_gas_E3_Revocation_revert_cold() public {
        uint256 g = _measure(
            address(revRevert), abi.encodeCall(E3_Revocation_Harness.checkExternal, ()), false
        );
        emit log_named_uint("E3_Revocation revert cold", g);
        assertApproxEqAbs(g, PRED_REV_REVERT_COLD, TOL, "E3_Revocation revert cold off prediction");
    }

    function test_gas_E3_Revocation_revert_warm() public {
        revRevert.active();
        uint256 g = _measure(
            address(revRevert), abi.encodeCall(E3_Revocation_Harness.checkExternal, ()), false
        );
        emit log_named_uint("E3_Revocation revert warm", g);
        assertApproxEqAbs(g, PRED_REV_REVERT_WARM, TOL, "E3_Revocation revert warm off prediction");
    }
}
